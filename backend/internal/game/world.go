package game

import (
	"fmt"
	"math"
	"math/rand"
)

const (
	maxGrenades = 8
	maxSmokes   = 8
)

// Spawn es un punto de aparición simétrico.
type Spawn struct {
	X, Y float64
	Team int
}

// TracerEvent: trazadora creada en este tick (evento efímero para el cliente).
type TracerEvent struct {
	X1, Y1, X2, Y2 float64
	R, G, B        float64
}

// KillEvent: una baja ocurrida en este tick.
type KillEvent struct {
	Victim, Killer int
	Weapon         string
}

// HitEvent: impacto confirmado en este tick. Permite al cliente del ATACANTE
// dibujar un hitmarker autoritativo (no adivinado). Kill marca si remató.
type HitEvent struct {
	Attacker int
	Kill     bool
}

// BreakEvent: una cobertura destruible se rompió en este tick (HP <= 0). El
// cliente lo usa para lanzar partículas de escombros y dejar de dibujarla.
type BreakEvent struct {
	ID int
}

// Match controla rondas, temporizador, overtime, bandera y marcador.
type Match struct {
	RoundDuration    float64
	CaptureDuration  float64
	CaptureRadius    float64
	OvertimeDuration float64 // tope duro del overtime (muerte súbita)
	RoundsToWin      int

	Scores      [2]int
	RoundNumber int
	Phase       string // idle | active | overtime | ended
	RoundTime   float64
	RoundWinner int // -1 ninguno, 0 empate, 1/2 equipo
	MatchOver   bool
	MatchWinner int

	CurrentLoadout LoadoutDef
	HasLoadout     bool

	Flag struct {
		X, Y, R float64
		Active  bool
	}
	CaptureProgress float64
	CaptureTeam     int
	OvertimeTime    float64 // tiempo transcurrido en overtime
}

func newMatch() *Match {
	m := &Match{
		RoundDuration:    40,
		CaptureDuration:  3,
		CaptureRadius:    70,
		OvertimeDuration: 25,
		RoundsToWin:      4,
		RoundWinner:      -1,
	}
	return m
}

func (m *Match) ResetMatch() {
	m.Scores = [2]int{}
	m.RoundNumber = 0
	m.Phase = "idle"
	m.RoundWinner = -1
	m.MatchOver = false
	m.MatchWinner = 0
	m.HasLoadout = false
	m.CaptureProgress = 0
	m.CaptureTeam = 0
	m.OvertimeTime = 0
}

func (m *Match) CaptureFraction() float64 { return m.CaptureProgress / m.CaptureDuration }

// World es el estado autoritativo completo del juego (una "sala").
type World struct {
	Mode   int
	Bounds AABB
	Walls  []AABB   // muros de concreto indestructibles (estáticos)
	Covers []Cover  // parapetos de madera destruibles
	Solids []AABB   // muros + coberturas activas; usado por colisión/movimiento

	Players []*Player
	Spawns  []Spawn

	Grenades []*Grenade
	Smokes   []Smoke

	Match *Match

	// Fase de alto nivel: waiting | intro | active | overtime | roundend | matchend
	GamePhase     string
	IntroTimer    float64
	EndTimer      float64
	MatchEndTimer float64

	// Eventos de este tick, drenados por la capa de red.
	Tracers []TracerEvent
	Kills   []KillEvent
	Hits    []HitEvent
	Breaks  []BreakEvent

	rng *rand.Rand
}

func NewWorld(mode int) *World {
	if mode != 2 {
		mode = 1
	}
	w := &World{
		Mode:      mode,
		Match:     newMatch(),
		GamePhase: "waiting",
		rng:       rand.New(rand.NewSource(rand.Int63())),
	}
	w.buildMap()
	w.buildPlayers()

	w.Grenades = make([]*Grenade, maxGrenades)
	for i := range w.Grenades {
		w.Grenades[i] = &Grenade{}
	}
	w.Smokes = make([]Smoke, maxSmokes)
	return w
}

func (w *World) buildMap() {
	w.Bounds, w.Walls, w.Covers = buildArena()
	w.rebuildSolids()
}

// rebuildSolids recompone la lista de rectángulos sólidos (muros + coberturas
// ACTIVAS) que usan el movimiento y el raycast. Reutiliza el backing array, así
// que no asigna en régimen permanente: solo se llama al iniciar ronda y cuando
// una cobertura se rompe (eventos raros).
func (w *World) rebuildSolids() {
	w.Solids = w.Solids[:0]
	w.Solids = append(w.Solids, w.Walls...)
	for i := range w.Covers {
		if w.Covers[i].Active {
			w.Solids = append(w.Solids, w.Covers[i].Box)
		}
	}
}

// resetCovers restaura todas las coberturas destruibles al inicio de ronda.
func (w *World) resetCovers() {
	for i := range w.Covers {
		w.Covers[i].HP = w.Covers[i].MaxHP
		w.Covers[i].Active = true
	}
	w.rebuildSolids()
}

// damageCover aplica daño hitscan a una cobertura; si la destruye, emite el
// evento de ruptura y la saca de la colisión.
func (w *World) damageCover(idx int, amount float64) {
	c := &w.Covers[idx]
	if !c.Active {
		return
	}
	c.HP -= amount
	if c.HP <= 0 {
		c.HP = 0
		c.Active = false
		w.Breaks = append(w.Breaks, BreakEvent{ID: c.ID})
		w.rebuildSolids()
	}
}

func (w *World) buildPlayers() {
	b := w.Bounds
	cy := b.Y + b.H/2
	n := w.Mode // jugadores por equipo

	spread := func(i int) float64 {
		if n == 1 {
			return cy
		}
		return cy + (float64(i)-(float64(n)+1)/2)*140
	}

	id := 0
	for i := 1; i <= n; i++ {
		id++
		p := NewPlayer(id, 1, fmt.Sprintf("Azul %d", i))
		p.IsBot = true
		w.Players = append(w.Players, p)
		w.Spawns = append(w.Spawns, Spawn{b.X + 90, spread(i), 1})
	}
	for i := 1; i <= n; i++ {
		id++
		p := NewPlayer(id, 2, fmt.Sprintf("Rojo %d", i))
		p.IsBot = true
		w.Players = append(w.Players, p)
		w.Spawns = append(w.Spawns, Spawn{b.X + b.W - 90, spread(i), 2})
	}
}

// ApplyInput fija el input de un jugador humano (id = índice+1).
//
// Los FLANCOS (FirePressed/Reload/Swap) se ACUMULAN con OR sobre el input aún
// no consumido: si llegan varios paquetes en el mismo tick (jitter de red),
// ninguna pulsación se pierde. player.Update los limpia tras consumirlos, así
// que p.In solo tiene flancos pendientes desde el último tick simulado.
func (w *World) ApplyInput(id int, in Input) {
	if id < 1 || id > len(w.Players) {
		return
	}
	p := w.Players[id-1]
	if p.IsBot {
		return
	}
	in.FirePressed = in.FirePressed || p.In.FirePressed
	in.Reload = in.Reload || p.In.Reload
	in.Swap = in.Swap || p.In.Swap
	p.In = in
}

// Start arranca la primera ronda (llamado por la red al unirse el 1er humano).
func (w *World) Start() {
	if w.GamePhase == "waiting" {
		w.beginRound()
	}
}

func (w *World) beginRound() {
	w.Match.StartRound(w)
	w.GamePhase = "intro"
	w.IntroTimer = 2.5
}

// ===================== Lógica de fuego (autoritativa) =====================

func (w *World) fireWeapon(p *Player, weapon *Weapon, aim float64) bool {
	if !weapon.CanFire() {
		if !weapon.HasAmmo() {
			weapon.StartReload()
		}
		return false
	}
	def := weapon.Def
	weapon.FireTimer = def.FireDelay
	if def.MagSize > 0 {
		weapon.Ammo--
	}
	ox, oy := p.Pos.X, p.Pos.Y

	switch def.Type {
	case Hitscan:
		ang := aim + (w.rng.Float64()*2-1)*def.Spread
		dx, dy := math.Cos(ang), math.Sin(ang)
		hit := w.Cast(ox, oy, dx, dy, def.Range, p, true)
		w.addTracer(ox, oy, hit.X, hit.Y, def)
		if hit.Hit {
			if hit.Kind == HitPlayer {
				w.applyDamage(hit.Target, def.Damage, p, def.ID)
			} else if hit.Kind == HitCover {
				w.damageCover(hit.CoverIdx, def.Damage)
			}
		}
	case Melee:
		for _, e := range w.Players {
			if e != p && e.Alive && e.Team != p.Team {
				if p.Pos.Dist(e.Pos) <= def.Range+e.Radius {
					to := p.Pos.AngleTo(e.Pos)
					// diferencia angular normalizada a [-pi,pi]
					diff := math.Abs(math.Atan2(math.Sin(to-aim), math.Cos(to-aim)))
					if diff <= def.Arc*0.5 {
						w.applyDamage(e, def.Damage, p, def.ID)
					}
				}
			}
		}
		w.addTracer(ox, oy, ox+math.Cos(aim)*def.Range, oy+math.Sin(aim)*def.Range, def)
	case Projectile:
		vel := Vec{math.Cos(aim) * def.ThrowSpeed, math.Sin(aim) * def.ThrowSpeed}
		w.spawnGrenade(Vec{ox, oy}, vel, def, p)
	}
	return true
}

func (w *World) applyDamage(target *Player, amount float64, attacker *Player, weaponID string) {
	wasAlive := target.Alive
	killed := target.ApplyDamage(amount, attacker)
	// Impacto confirmado para el hitmarker del atacante (solo si hizo daño real).
	if attacker != nil && wasAlive && amount > 0 {
		w.Hits = append(w.Hits, HitEvent{Attacker: attacker.ID, Kill: killed})
	}
	if killed {
		killer := 0
		if attacker != nil {
			killer = attacker.ID
		}
		w.Kills = append(w.Kills, KillEvent{Victim: target.ID, Killer: killer, Weapon: weaponID})
	}
}

func (w *World) addTracer(x1, y1, x2, y2 float64, def *WeaponDef) {
	w.Tracers = append(w.Tracers, TracerEvent{x1, y1, x2, y2, def.TracerR, def.TracerG, def.TracerB})
}

func (w *World) spawnGrenade(pos, vel Vec, def *WeaponDef, owner *Player) {
	for _, g := range w.Grenades {
		if !g.Active {
			g.Launch(pos, vel, def, owner)
			return
		}
	}
}

func (w *World) detonate(g *Grenade) {
	for i := range w.Smokes {
		if !w.Smokes[i].Active {
			w.Smokes[i].Detonate(g.Pos.X, g.Pos.Y, g.Def)
			return
		}
	}
}

func (w *World) clearTransient() {
	for _, g := range w.Grenades {
		g.Active = false
	}
	for i := range w.Smokes {
		w.Smokes[i].Active = false
	}
}

// ===================== Simulación =====================

// ClearEvents descarta los eventos efímeros (tracers/kills) acumulados.
// Lo llama la capa de red TRAS emitir un snapshot, de modo que los eventos de
// TODOS los sub-pasos de un frame se incluyan en el mismo paquete.
func (w *World) ClearEvents() {
	w.Tracers = w.Tracers[:0]
	w.Kills = w.Kills[:0]
	w.Hits = w.Hits[:0]
	w.Breaks = w.Breaks[:0]
}

// Step avanza el mundo un paso fijo dt según la fase de alto nivel.
func (w *World) Step(dt float64) {
	switch w.GamePhase {
	case "waiting":
		return

	case "intro":
		w.IntroTimer -= dt
		if w.IntroTimer <= 0 {
			w.GamePhase = "active"
		}

	case "active", "overtime":
		w.stepBots(dt)
		w.stepPhysics(dt)
		phase := w.Match.Update(dt, w)
		if phase == "ended" {
			w.GamePhase = "roundend"
			w.EndTimer = 3.0
		} else if phase == "overtime" {
			w.GamePhase = "overtime"
		}

	case "roundend":
		w.EndTimer -= dt
		if w.EndTimer <= 0 {
			if w.Match.MatchOver {
				w.GamePhase = "matchend"
				w.MatchEndTimer = 6.0
			} else {
				w.beginRound()
			}
		}

	case "matchend":
		w.MatchEndTimer -= dt
		if w.MatchEndTimer <= 0 {
			w.Match.ResetMatch()
			w.beginRound()
		}
	}
}

func (w *World) stepBots(dt float64) {
	for _, p := range w.Players {
		if p.IsBot {
			w.botThink(p, dt)
		}
	}
}

func (w *World) stepPhysics(dt float64) {
	for _, p := range w.Players {
		p.Update(dt, w)
	}
	for _, g := range w.Grenades {
		if g.Active && g.Update(dt, w) {
			w.detonate(g)
		}
	}
	for i := range w.Smokes {
		if w.Smokes[i].Active {
			w.Smokes[i].Update(dt)
		}
	}
}

// ===================== IA de bots =====================

func (w *World) botThink(p *Player, dt float64) {
	p.In = Input{}
	if !p.Alive {
		return
	}
	ai := &p.AI

	var target *Player
	best := math.Inf(1)
	for _, e := range w.Players {
		if e.Team != p.Team && e.Alive {
			if d := p.Pos.DistSq(e.Pos); d < best {
				best, target = d, e
			}
		}
	}

	var goalX, goalY float64
	hasGoal := false
	if w.Match.Phase == "overtime" {
		goalX, goalY, hasGoal = w.Match.Flag.X, w.Match.Flag.Y, true
	} else if target != nil {
		goalX, goalY, hasGoal = target.Pos.X, target.Pos.Y, true
	}

	if target != nil {
		p.In.Aim = math.Atan2(target.Pos.Y-p.Pos.Y, target.Pos.X-p.Pos.X)
		dx, dy := math.Cos(p.In.Aim), math.Sin(p.In.Aim)
		hit := w.Cast(p.Pos.X, p.Pos.Y, dx, dy, 2000, p, true)
		weapon := p.ActiveWeapon()
		ai.FireCd -= dt
		if hit.Hit && hit.Kind == HitPlayer && hit.Target == target {
			p.In.ADS = true
			if weapon != nil && weapon.CanFire() && ai.FireCd <= 0 {
				p.In.FirePressed = true
				p.In.Fire = true
				ai.FireCd = 0.12 + w.rng.Float64()*0.25
			}
		} else if weapon != nil && !weapon.HasAmmo() {
			p.In.Reload = true
		}
	}

	if hasGoal {
		dirA := math.Atan2(goalY-p.Pos.Y, goalX-p.Pos.X)
		dist := math.Sqrt(best)
		approach := 1.0
		if w.Match.Phase != "overtime" && dist < 260 {
			approach = -0.4
		}
		ai.StrafeCd -= dt
		if ai.StrafeCd <= 0 {
			if w.rng.Float64() < 0.5 {
				ai.StrafeDir = 1
			} else {
				ai.StrafeDir = -1
			}
			ai.StrafeCd = 0.6 + w.rng.Float64()
		}
		strafeA := dirA + math.Pi*0.5*ai.StrafeDir
		p.In.MoveX = math.Cos(dirA)*approach + math.Cos(strafeA)*0.6
		p.In.MoveY = math.Sin(dirA)*approach + math.Sin(strafeA)*0.6
	}
}

// ===================== Lógica de Match =====================

func (m *Match) StartRound(w *World) {
	m.RoundNumber++
	m.RoundTime = m.RoundDuration
	m.Phase = "active"
	m.RoundWinner = -1
	m.CaptureProgress = 0
	m.CaptureTeam = 0
	m.OvertimeTime = 0

	entry := Loadouts[w.rng.Intn(len(Loadouts))]
	m.CurrentLoadout = entry
	m.HasLoadout = true

	b := w.Bounds
	m.Flag.X = b.X + b.W*0.5
	m.Flag.Y = b.Y + b.H*0.5
	m.Flag.R = m.CaptureRadius
	m.Flag.Active = false

	for i, p := range w.Players {
		sp := w.Spawns[i]
		p.Spawn(sp.X, sp.Y, entry)
	}
	w.clearTransient()
	w.resetCovers() // restaura todos los parapetos a vida completa
}

func (m *Match) tallies(w *World) (alive1, alive2, inFlag1, inFlag2 int) {
	r2 := m.Flag.R * m.Flag.R
	for _, p := range w.Players {
		if !p.Alive {
			continue
		}
		if p.Team == 1 {
			alive1++
		} else {
			alive2++
		}
		dx, dy := p.Pos.X-m.Flag.X, p.Pos.Y-m.Flag.Y
		if dx*dx+dy*dy <= r2 {
			if p.Team == 1 {
				inFlag1++
			} else {
				inFlag2++
			}
		}
	}
	return
}

func (m *Match) Update(dt float64, w *World) string {
	if m.Phase == "ended" || m.Phase == "idle" {
		return m.Phase
	}
	alive1, alive2, inFlag1, inFlag2 := m.tallies(w)

	// 1) Eliminación.
	if alive1 == 0 || alive2 == 0 {
		switch {
		case alive1 == 0 && alive2 == 0:
			m.RoundWinner = 0
		case alive1 == 0:
			m.RoundWinner = 2
		default:
			m.RoundWinner = 1
		}
		return m.endRound()
	}

	// 2) Fase activa: reloj.
	if m.Phase == "active" {
		m.RoundTime -= dt
		if m.RoundTime <= 0 {
			m.RoundTime = 0
			m.Phase = "overtime"
			m.Flag.Active = true
			m.CaptureProgress = 0
			m.CaptureTeam = 0
		}
		return m.Phase
	}

	// 3) Overtime: captura de bandera.
	if m.Phase == "overtime" {
		m.OvertimeTime += dt
		capturing := 0
		if inFlag1 > 0 && inFlag2 == 0 {
			capturing = 1
		} else if inFlag2 > 0 && inFlag1 == 0 {
			capturing = 2
		}
		if capturing == 0 {
			m.CaptureTeam = 0
			m.CaptureProgress = 0
		} else {
			if capturing != m.CaptureTeam {
				m.CaptureTeam = capturing
				m.CaptureProgress = 0
			}
			m.CaptureProgress += dt
			if m.CaptureProgress >= m.CaptureDuration {
				m.RoundWinner = capturing
				return m.endRound()
			}
		}
		// Muerte súbita: si el overtime se eterniza sin captura ni bajas,
		// gana quien tenga más vida total (empate si igual). Garantiza fin.
		if m.OvertimeTime >= m.OvertimeDuration {
			m.RoundWinner = decideByHP(w)
			return m.endRound()
		}
		return m.Phase
	}

	return m.Phase
}

// decideByHP devuelve el equipo con más vida total entre los vivos (0 = empate).
func decideByHP(w *World) int {
	var hp1, hp2 float64
	for _, p := range w.Players {
		if !p.Alive {
			continue
		}
		if p.Team == 1 {
			hp1 += p.HP
		} else {
			hp2 += p.HP
		}
	}
	if hp1 > hp2 {
		return 1
	}
	if hp2 > hp1 {
		return 2
	}
	return 0
}

func (m *Match) endRound() string {
	m.Phase = "ended"
	m.Flag.Active = false
	wnr := m.RoundWinner
	if wnr == 1 || wnr == 2 {
		m.Scores[wnr-1]++
		if m.Scores[wnr-1] >= m.RoundsToWin {
			m.MatchOver = true
			m.MatchWinner = wnr
		}
	}
	return m.Phase
}
