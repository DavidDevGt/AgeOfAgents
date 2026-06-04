package game

import "math"

// Grenade es un proyectil físico (humo) en vuelo.
type Grenade struct {
	Pos    Vec
	Vel    Vec
	Radius float64
	Fuse   float64
	Def    *WeaponDef
	Owner  *Player
	Active bool
}

func (g *Grenade) Launch(pos, vel Vec, def *WeaponDef, owner *Player) {
	g.Pos, g.Vel = pos, vel
	g.Radius = 5
	g.Fuse = def.Fuse
	g.Def = def
	g.Owner = owner
	g.Active = true
}

// Update integra la granada con fricción y colisión deslizante.
// Devuelve true cuando debe detonar (fusible agotado).
func (g *Grenade) Update(dt float64, w *World) bool {
	if !g.Active {
		return false
	}
	f := 1 - g.Def.Friction*dt
	if f < 0 {
		f = 0
	}
	g.Vel = g.Vel.Scale(f)
	MoveAndSlide(&g.Pos, g.Radius, g.Vel.X*dt, g.Vel.Y*dt, w.Solids, w.Bounds)
	g.Fuse -= dt
	if g.Fuse <= 0 {
		g.Active = false
		return true
	}
	return false
}

// Smoke es la nube resultante tras detonar una granada de humo.
type Smoke struct {
	X, Y    float64
	R       float64
	MaxR    float64
	Time    float64
	MaxTime float64
	Active  bool
}

func (s *Smoke) Detonate(x, y float64, def *WeaponDef) {
	s.X, s.Y = x, y
	s.MaxR = def.SmokeRadius
	s.R = def.SmokeRadius * 0.2
	s.Time = def.SmokeTime
	s.MaxTime = def.SmokeTime
	s.Active = true
}

func (s *Smoke) Update(dt float64) {
	if !s.Active {
		return
	}
	if s.R < s.MaxR {
		s.R = math.Min(s.MaxR, s.R+s.MaxR*3*dt)
	}
	s.Time -= dt
	if s.Time <= 0 {
		s.Active = false
		s.R = 0
	}
}
