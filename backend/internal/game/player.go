package game

import "math"

const (
	PlayerSpeed  = 235.0
	PlayerRadius = 14.0
	MaxHP        = 100.0
	fireFlash    = 0.06
)

// Input es el comando que controla a un jugador en un tick. Para humanos lo
// rellena la capa de red; para bots lo rellena la IA. Los flancos
// (FirePressed/Reload/Swap) son de UN SOLO USO: el jugador los consume y los
// limpia, de modo que un paquete de input retenido no los repite cada tick.
type Input struct {
	MoveX, MoveY float64
	Aim          float64
	Fire         bool // gatillo mantenido (auto)
	FirePressed  bool // flanco
	ADS          bool
	Reload       bool // flanco
	Swap         bool // flanco
}

// BotAI guarda el estado temporal de la IA de un bot.
type BotAI struct {
	FireCd    float64
	StrafeCd  float64
	StrafeDir float64
}

type Player struct {
	ID    int
	Team  int
	Name  string
	IsBot bool

	Pos    Vec
	Vel    Vec
	Radius float64
	Aim    float64

	MaxHP        float64
	HP           float64
	Alive        bool
	LastAttacker *Player

	Loadout *Loadout
	Slot    string // "primary" | "secondary"

	State     string // idle | walking | aiming | firing | dead
	FireFlash float64

	In Input
	AI BotAI
}

func NewPlayer(id, team int, name string) *Player {
	return &Player{
		ID: id, Team: team, Name: name,
		Radius: PlayerRadius, MaxHP: MaxHP, HP: MaxHP, Alive: true,
		Slot: "primary", State: "idle",
		AI: BotAI{StrafeDir: 1},
	}
}

// Spawn reinicia al jugador para una nueva ronda en (x,y) con el loadout dado.
func (p *Player) Spawn(x, y float64, def LoadoutDef) {
	p.Pos = Vec{x, y}
	p.Vel = Vec{}
	p.HP = p.MaxHP
	p.Alive = true
	p.LastAttacker = nil
	p.State = "idle"
	p.FireFlash = 0
	p.Slot = "primary"
	p.Loadout = BuildLoadout(def)
}

func (p *Player) ActiveWeapon() *Weapon {
	if p.Loadout == nil {
		return nil
	}
	if p.Slot == "secondary" {
		return p.Loadout.Secondary
	}
	return p.Loadout.Primary
}

// Update aplica la lógica autoritativa del jugador para un tick.
func (p *Player) Update(dt float64, w *World) {
	if !p.Alive {
		p.State = "dead"
		return
	}
	in := &p.In
	p.Aim = in.Aim

	if in.Swap {
		if p.Slot == "primary" {
			p.Slot = "secondary"
		} else {
			p.Slot = "primary"
		}
	}

	weapon := p.ActiveWeapon()
	if in.Reload && weapon != nil {
		weapon.StartReload()
	}

	// ---- Movimiento (dirección normalizada: la diagonal no acelera) ----
	mx, my := in.MoveX, in.MoveY
	mlen := mx*mx + my*my
	if mlen > 1 {
		inv := 1 / math.Sqrt(mlen)
		mx, my = mx*inv, my*inv
	}
	speed := PlayerSpeed
	if in.ADS && weapon != nil {
		speed *= weapon.Def.ADSMoveMult
	}
	p.Vel = Vec{mx * speed, my * speed}
	MoveAndSlide(&p.Pos, p.Radius, p.Vel.X*dt, p.Vel.Y*dt, w.Walls, w.Bounds)

	// ---- Armas ----
	if weapon != nil {
		weapon.Update(dt)
		def := weapon.Def
		wantFire := (def.Auto && in.Fire) || in.FirePressed
		if wantFire {
			if w.fireWeapon(p, weapon, p.Aim) {
				p.FireFlash = fireFlash
			}
		}
	}

	// ---- FSM visual ----
	switch {
	case p.FireFlash > 0:
		p.FireFlash -= dt
		p.State = "firing"
	case in.ADS:
		p.State = "aiming"
	case mlen > 1e-4:
		p.State = "walking"
	default:
		p.State = "idle"
	}

	// Consumir flancos de un solo uso.
	in.FirePressed = false
	in.Reload = false
	in.Swap = false
}

// ApplyDamage descuenta vida de forma permanente (sin regeneración).
// Devuelve true si este golpe mató al jugador.
func (p *Player) ApplyDamage(amount float64, attacker *Player) bool {
	if !p.Alive || amount <= 0 {
		return false
	}
	p.HP -= amount
	p.LastAttacker = attacker
	if p.HP <= 0 {
		p.HP = 0
		p.Alive = false
		p.State = "dead"
		return true
	}
	return false
}
