package netcode

// protocol.go — protocolo de texto sobre UDP. Elegimos texto (líneas separadas
// por '\n', campos por '|') en vez de binario porque LÖVE corre sobre LuaJIT,
// que NO trae string.pack; así el cliente Lua parsea con string.gmatch sin
// dependencias. El volumen (2-8 entidades a 30 Hz) hace el coste irrelevante.
//
// Cliente -> Servidor:
//   "J"                          unirse
//   "I|seq|mx|my|aim|btn"        input (btn = máscara de bits)
//   "B"                          salir
//
// Servidor -> Cliente (un datagrama, varias líneas):
//   "W|id|mode|bx|by|bw|bh"  +  "WALL|x|y|w|h" por muro     (bienvenida, 1 vez)
//   "S|..."  + "F|..." + "P|..."(xN) + "K|..." + "G|..." + "T|..." + "D|..."

import (
	"bytes"
	"strconv"
	"strings"

	"gulagarena/internal/game"
)

// Máscara de botones del input.
const (
	BtnFire        = 1 << 0
	BtnFirePressed = 1 << 1
	BtnADS         = 1 << 2
	BtnReload      = 1 << 3
	BtnSwap        = 1 << 4
)

// DecodeInput parsea "I|seq|mx|my|aim|btn". Devuelve seq, input y ok.
func DecodeInput(parts []string) (seq int, in game.Input, ok bool) {
	if len(parts) < 6 {
		return 0, in, false
	}
	seq, _ = strconv.Atoi(parts[1])
	mx, _ := strconv.ParseFloat(parts[2], 64)
	my, _ := strconv.ParseFloat(parts[3], 64)
	aim, _ := strconv.ParseFloat(parts[4], 64)
	btn, _ := strconv.Atoi(parts[5])

	in.MoveX, in.MoveY, in.Aim = mx, my, aim
	in.Fire = btn&BtnFire != 0
	in.FirePressed = btn&BtnFirePressed != 0
	in.ADS = btn&BtnADS != 0
	in.Reload = btn&BtnReload != 0
	in.Swap = btn&BtnSwap != 0
	return seq, in, true
}

// EncodeWelcome construye el mensaje de bienvenida con el mapa estático.
func EncodeWelcome(w *game.World, playerID int) []byte {
	var b strings.Builder
	b.WriteString("W|")
	b.WriteString(strconv.Itoa(playerID))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(w.Mode))
	writeRect(&b, w.Bounds.X, w.Bounds.Y, w.Bounds.W, w.Bounds.H)
	for i := range w.Walls {
		wl := w.Walls[i]
		b.WriteString("\nWALL|")
		b.WriteString(f1(wl.X))
		b.WriteByte('|')
		b.WriteString(f1(wl.Y))
		b.WriteByte('|')
		b.WriteString(f1(wl.W))
		b.WriteByte('|')
		b.WriteString(f1(wl.H))
	}
	return []byte(b.String())
}

// EncodeSnapshot serializa el estado dinámico del mundo en el buffer dado y
// devuelve sus bytes. El buffer lo posee y reutiliza el servidor: así no se
// asigna memoria nueva por broadcast (30 Hz).
func EncodeSnapshot(b *bytes.Buffer, w *game.World) []byte {
	m := w.Match
	b.Reset()

	// Estado global.
	b.WriteString("S|")
	b.WriteString(w.GamePhase)
	b.WriteByte('|')
	b.WriteString(m.Phase)
	b.WriteByte('|')
	b.WriteString(f1(m.RoundTime))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.Scores[0]))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.Scores[1]))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.RoundNumber))
	b.WriteByte('|')
	b.WriteString(loadoutName(m))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.RoundWinner))
	b.WriteByte('|')
	b.WriteString(boolc(m.MatchOver))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.MatchWinner))
	b.WriteByte('|')
	b.WriteString(f2(w.IntroTimer))
	b.WriteByte('|')
	b.WriteString(f2(w.EndTimer))

	// Bandera.
	b.WriteString("\nF|")
	b.WriteString(boolc(m.Flag.Active))
	b.WriteByte('|')
	b.WriteString(f1(m.Flag.X))
	b.WriteByte('|')
	b.WriteString(f1(m.Flag.Y))
	b.WriteByte('|')
	b.WriteString(f1(m.Flag.R))
	b.WriteByte('|')
	b.WriteString(f2(m.CaptureFraction()))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(m.CaptureTeam))
	b.WriteByte('|')
	overtimeLeft := 0.0
	if m.Phase == "overtime" {
		overtimeLeft = m.OvertimeDuration - m.OvertimeTime
		if overtimeLeft < 0 {
			overtimeLeft = 0
		}
	}
	b.WriteString(f1(overtimeLeft))

	// Jugadores.
	for _, p := range w.Players {
		b.WriteString("\nP|")
		b.WriteString(strconv.Itoa(p.ID))
		b.WriteByte('|')
		b.WriteString(strconv.Itoa(p.Team))
		b.WriteByte('|')
		b.WriteString(f1(p.Pos.X))
		b.WriteByte('|')
		b.WriteString(f1(p.Pos.Y))
		b.WriteByte('|')
		b.WriteString(f3(p.Aim))
		b.WriteByte('|')
		b.WriteString(f1(p.HP))
		b.WriteByte('|')
		b.WriteString(boolc(p.Alive))
		b.WriteByte('|')
		b.WriteString(p.State)
		b.WriteByte('|')
		b.WriteString(p.Slot)
		// Info de arma activa (para el HUD).
		name, ammo, mag, reloading := "-", -1, 0, false
		if wpn := p.ActiveWeapon(); wpn != nil {
			name = wpn.Def.Name
			ammo = wpn.Ammo
			mag = wpn.Def.MagSize
			reloading = wpn.Reloading
		}
		b.WriteByte('|')
		b.WriteString(name)
		b.WriteByte('|')
		b.WriteString(strconv.Itoa(ammo))
		b.WriteByte('|')
		b.WriteString(strconv.Itoa(mag))
		b.WriteByte('|')
		b.WriteString(boolc(reloading))
	}

	// Humos activos.
	for i := range w.Smokes {
		s := &w.Smokes[i]
		if s.Active {
			b.WriteString("\nK|")
			b.WriteString(f1(s.X))
			b.WriteByte('|')
			b.WriteString(f1(s.Y))
			b.WriteByte('|')
			b.WriteString(f1(s.R))
		}
	}

	// Granadas en vuelo.
	for _, g := range w.Grenades {
		if g.Active {
			b.WriteString("\nG|")
			b.WriteString(f1(g.Pos.X))
			b.WriteByte('|')
			b.WriteString(f1(g.Pos.Y))
		}
	}

	// Trazadoras de este tick (eventos efímeros).
	for i := range w.Tracers {
		t := &w.Tracers[i]
		b.WriteString("\nT|")
		b.WriteString(f1(t.X1))
		b.WriteByte('|')
		b.WriteString(f1(t.Y1))
		b.WriteByte('|')
		b.WriteString(f1(t.X2))
		b.WriteByte('|')
		b.WriteString(f1(t.Y2))
		b.WriteByte('|')
		b.WriteString(f2(t.R))
		b.WriteByte('|')
		b.WriteString(f2(t.G))
		b.WriteByte('|')
		b.WriteString(f2(t.B))
	}

	// Bajas de este tick.
	for i := range w.Kills {
		k := &w.Kills[i]
		b.WriteString("\nD|")
		b.WriteString(strconv.Itoa(k.Victim))
		b.WriteByte('|')
		b.WriteString(strconv.Itoa(k.Killer))
		b.WriteByte('|')
		b.WriteString(k.Weapon)
	}

	return b.Bytes()
}

// ---- helpers de formato compacto ----

func writeRect(b *strings.Builder, x, y, w, h float64) {
	b.WriteByte('|')
	b.WriteString(f1(x))
	b.WriteByte('|')
	b.WriteString(f1(y))
	b.WriteByte('|')
	b.WriteString(f1(w))
	b.WriteByte('|')
	b.WriteString(f1(h))
}

func f1(v float64) string { return strconv.FormatFloat(v, 'f', 1, 64) }
func f2(v float64) string { return strconv.FormatFloat(v, 'f', 2, 64) }
func f3(v float64) string { return strconv.FormatFloat(v, 'f', 3, 64) }

func boolc(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func loadoutName(m *game.Match) string {
	if m.HasLoadout {
		return m.CurrentLoadout.Name
	}
	return "-"
}
