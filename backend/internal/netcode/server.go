package netcode

// server.go — servidor UDP autoritativo. Modelo de concurrencia simple y seguro:
//   * Una goroutine LECTORA solo recibe datagramas y los empuja a un canal.
//   * El BUCLE PRINCIPAL (único dueño de world y sessions) drena el canal,
//     avanza la simulación a paso fijo y emite snapshots.
// Así toda mutación de estado ocurre en una sola goroutine: cero mutexes.

import (
	"bytes"
	"log"
	"net"
	"strings"
	"time"

	"gulagarena/internal/game"
)

const (
	tickRate       = 60
	fixedDT        = 1.0 / tickRate
	snapshotEveryN = 2 // emitir snapshot cada 2 ticks => 30 Hz
	clientTimeout  = 5 * time.Second
	maxCatchup     = 0.25 // evita "spiral of death" tras una pausa
	statsEvery     = 5 * time.Second
)

type session struct {
	addr     *net.UDPAddr
	playerID int
	lastSeen time.Time
}

type packet struct {
	addr *net.UDPAddr
	data string
}

// stats acumula contadores de telemetría entre volcados de log.
type stats struct {
	ticks, snaps, pkts int
	bytesIn, bytesOut  int64
	since              time.Time
}

type Server struct {
	conn     *net.UDPConn
	world    *game.World
	sessions map[string]*session
	incoming chan packet
	debug    bool

	snapBuf *bytes.Buffer // buffer de snapshot reutilizado (sin GC por broadcast)

	// Telemetría de debug.
	st        stats
	prevPhase string
}

func NewServer(addr string, mode int, debug bool) (*Server, error) {
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return nil, err
	}
	return &Server{
		conn:      conn,
		world:     game.NewWorld(mode),
		sessions:  make(map[string]*session),
		incoming:  make(chan packet, 256),
		debug:     debug,
		snapBuf:   bytes.NewBuffer(make([]byte, 0, 2048)),
		st:        stats{since: time.Now()},
		prevPhase: "waiting",
	}, nil
}

func (s *Server) Run() {
	log.Printf("Gulag Arena server escuchando en %s (modo %dv%d, %d Hz, debug=%v)",
		s.conn.LocalAddr(), s.world.Mode, s.world.Mode, tickRate, s.debug)

	go s.readLoop()

	ticker := time.NewTicker(time.Second / tickRate)
	defer ticker.Stop()

	prev := time.Now()
	acc := 0.0
	tick := 0

	for range ticker.C {
		now := time.Now()
		s.drain()

		// Sin clientes: no simulamos (CPU ~0). Reanuda al unirse alguien.
		if len(s.sessions) == 0 {
			prev, acc = now, 0
			continue
		}

		frame := now.Sub(prev).Seconds()
		prev = now
		if frame > maxCatchup {
			frame = maxCatchup
		}
		acc += frame

		sendSnap := false
		for acc >= fixedDT {
			s.world.Step(fixedDT)
			acc -= fixedDT
			tick++
			s.st.ticks++
			if tick%snapshotEveryN == 0 {
				sendSnap = true
			}
		}
		if sendSnap {
			s.broadcast()
			if s.debug {
				s.logKills()
			}
			s.world.ClearEvents()
		}
		if s.debug {
			s.logTransitions()
			s.logStats(now)
		}
		s.checkTimeouts(now)
	}
}

func (s *Server) readLoop() {
	buf := make([]byte, 2048)
	for {
		n, addr, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		// Copiamos los bytes: buf se reutiliza en la próxima lectura.
		s.incoming <- packet{addr: addr, data: string(buf[:n])}
	}
}

// drain procesa todos los paquetes pendientes sin bloquear.
func (s *Server) drain() {
	for {
		select {
		case p := <-s.incoming:
			s.handle(p)
		default:
			return
		}
	}
}

func (s *Server) handle(p packet) {
	s.st.pkts++
	s.st.bytesIn += int64(len(p.data))

	data := strings.TrimSpace(p.data)
	if data == "" {
		return
	}
	parts := strings.Split(data, "|")
	key := p.addr.String()

	switch parts[0] {
	case "J":
		if s.sessions[key] != nil {
			s.conn.WriteToUDP(EncodeWelcome(s.world, s.sessions[key].playerID), p.addr)
			return
		}
		id := s.assignSlot()
		if id == 0 {
			s.conn.WriteToUDP([]byte("FULL"), p.addr)
			return
		}
		s.sessions[key] = &session{addr: p.addr, playerID: id, lastSeen: time.Now()}
		s.conn.WriteToUDP(EncodeWelcome(s.world, id), p.addr)
		s.world.Start()
		log.Printf("Jugador %d (%s) se unió desde %s (%d sesiones)",
			id, s.pname(id), key, len(s.sessions))

	case "I":
		sess := s.sessions[key]
		if sess == nil {
			return
		}
		if _, in, ok := DecodeInput(parts); ok {
			s.world.ApplyInput(sess.playerID, in)
			sess.lastSeen = time.Now()
		}

	case "Q":
		// Ping: devolvemos el timestamp del cliente para medir RTT.
		if len(parts) >= 2 {
			s.conn.WriteToUDP([]byte("q|"+parts[1]), p.addr)
		}
		if sess := s.sessions[key]; sess != nil {
			sess.lastSeen = time.Now()
		}

	case "B":
		if sess := s.sessions[key]; sess != nil {
			s.freeSlot(sess.playerID)
			delete(s.sessions, key)
			log.Printf("Jugador %d salió", sess.playerID)
		}
	}
}

// assignSlot toma el primer hueco controlado por bot (id más bajo) para el humano.
func (s *Server) assignSlot() int {
	for _, pl := range s.world.Players {
		if pl.IsBot {
			pl.IsBot = false
			return pl.ID
		}
	}
	return 0
}

// freeSlot devuelve el control de un jugador a la IA.
func (s *Server) freeSlot(id int) {
	if id >= 1 && id <= len(s.world.Players) {
		pl := s.world.Players[id-1]
		pl.IsBot = true
		pl.In = game.Input{}
	}
}

func (s *Server) broadcast() {
	if len(s.sessions) == 0 {
		return
	}
	data := EncodeSnapshot(s.snapBuf, s.world)
	for _, sess := range s.sessions {
		s.conn.WriteToUDP(data, sess.addr)
		s.st.bytesOut += int64(len(data))
	}
	s.st.snaps++
}

func (s *Server) checkTimeouts(now time.Time) {
	for key, sess := range s.sessions {
		if now.Sub(sess.lastSeen) > clientTimeout {
			s.freeSlot(sess.playerID)
			delete(s.sessions, key)
			log.Printf("Jugador %d expiró por inactividad", sess.playerID)
		}
	}
}

// ===================== Telemetría de debug =====================

func (s *Server) pname(id int) string {
	if id >= 1 && id <= len(s.world.Players) {
		return s.world.Players[id-1].Name
	}
	return "?"
}

func (s *Server) logKills() {
	for i := range s.world.Kills {
		k := s.world.Kills[i]
		wn := k.Weapon
		if def := game.Weapons[k.Weapon]; def != nil {
			wn = def.Name
		}
		if k.Killer == 0 {
			log.Printf("  ☠ %s murió (%s)", s.pname(k.Victim), wn)
		} else {
			log.Printf("  ☠ %s → %s (%s)", s.pname(k.Killer), s.pname(k.Victim), wn)
		}
	}
}

func (s *Server) logTransitions() {
	cur := s.world.GamePhase
	if cur == s.prevPhase {
		return
	}
	m := s.world.Match
	switch cur {
	case "intro":
		log.Printf("── Ronda %d ──  Loadout: %s", m.RoundNumber, m.CurrentLoadout.Name)
	case "overtime":
		log.Printf("  ⏱ OVERTIME (bandera activa)")
	case "roundend":
		log.Printf("  Fin de ronda: ganador=%s  |  marcador %d-%d",
			winnerLabel(m.RoundWinner), m.Scores[0], m.Scores[1])
	case "matchend":
		log.Printf("══ PARTIDA: gana equipo %s  %d-%d ══",
			winnerLabel(m.MatchWinner), m.Scores[0], m.Scores[1])
	}
	s.prevPhase = cur
}

func (s *Server) logStats(now time.Time) {
	elapsed := now.Sub(s.st.since).Seconds()
	if elapsed < statsEvery.Seconds() {
		return
	}
	log.Printf("[stats] %.0f tick/s · %.0f snap/s · in %.1f kB/s · out %.1f kB/s · %d pkt/s · %d sesiones",
		float64(s.st.ticks)/elapsed,
		float64(s.st.snaps)/elapsed,
		float64(s.st.bytesIn)/elapsed/1024,
		float64(s.st.bytesOut)/elapsed/1024,
		int(float64(s.st.pkts)/elapsed),
		len(s.sessions))
	s.st = stats{since: now}
}

func winnerLabel(w int) string {
	switch w {
	case 1:
		return "AZUL"
	case 2:
		return "ROJO"
	case 0:
		return "EMPATE"
	default:
		return "?"
	}
}
