package game

import "math"

// RayKind clasifica qué golpeó un rayo hitscan.
type RayKind int

const (
	HitNone RayKind = iota
	HitWall
	HitCover
	HitPlayer
	HitSmoke
)

type RayResult struct {
	Hit      bool
	T        float64 // distancia a lo largo del rayo
	X, Y     float64 // punto de impacto
	Kind     RayKind
	Target   *Player // si Kind == HitPlayer
	CoverIdx int     // índice en w.Covers si Kind == HitCover
}

// rayAABB: intersección rayo-AABB por el método de los slabs.
func rayAABB(ox, oy, dx, dy float64, b AABB, maxT float64) (float64, bool) {
	tmin, tmax := 0.0, maxT
	if math.Abs(dx) < 1e-9 {
		if ox < b.X || ox > b.X+b.W {
			return 0, false
		}
	} else {
		inv := 1 / dx
		t1, t2 := (b.X-ox)*inv, (b.X+b.W-ox)*inv
		if t1 > t2 {
			t1, t2 = t2, t1
		}
		if t1 > tmin {
			tmin = t1
		}
		if t2 < tmax {
			tmax = t2
		}
		if tmin > tmax {
			return 0, false
		}
	}
	if math.Abs(dy) < 1e-9 {
		if oy < b.Y || oy > b.Y+b.H {
			return 0, false
		}
	} else {
		inv := 1 / dy
		t1, t2 := (b.Y-oy)*inv, (b.Y+b.H-oy)*inv
		if t1 > t2 {
			t1, t2 = t2, t1
		}
		if t1 > tmin {
			tmin = t1
		}
		if t2 < tmax {
			tmax = t2
		}
		if tmin > tmax {
			return 0, false
		}
	}
	return tmin, true
}

// rayCircle: intersección rayo-círculo (d normalizado).
func rayCircle(ox, oy, dx, dy, cx, cy, r, maxT float64) (float64, bool) {
	mx, my := ox-cx, oy-cy
	b := mx*dx + my*dy
	c := mx*mx + my*my - r*r
	if c > 0 && b > 0 {
		return 0, false
	}
	disc := b*b - c
	if disc < 0 {
		return 0, false
	}
	t := -b - math.Sqrt(disc)
	if t < 0 {
		t = 0
	}
	if t > maxT {
		return 0, false
	}
	return t, true
}

// Cast lanza un rayo unitario desde (ox,oy) hasta maxDist contra muros,
// jugadores enemigos vivos y (si blockBySmoke) nubes de humo.
func (w *World) Cast(ox, oy, dx, dy, maxDist float64, shooter *Player, blockBySmoke bool) RayResult {
	res := RayResult{T: maxDist}

	// Muros indestructibles primero.
	for i := range w.Walls {
		if t, ok := rayAABB(ox, oy, dx, dy, w.Walls[i], res.T); ok {
			res.Hit, res.T, res.Kind, res.Target = true, t, HitWall, nil
		}
	}

	// Coberturas destruibles activas: una bala que las toca se detiene (no
	// atraviesa) y nos dice qué cobertura golpeó para descontarle vida.
	for i := range w.Covers {
		if w.Covers[i].Active {
			if t, ok := rayAABB(ox, oy, dx, dy, w.Covers[i].Box, res.T); ok {
				res.Hit, res.T, res.Kind, res.Target, res.CoverIdx = true, t, HitCover, nil, i
			}
		}
	}

	if blockBySmoke {
		for i := range w.Smokes {
			s := &w.Smokes[i]
			if s.Active {
				if t, ok := rayCircle(ox, oy, dx, dy, s.X, s.Y, s.R, res.T); ok {
					res.Hit, res.T, res.Kind, res.Target = true, t, HitSmoke, nil
				}
			}
		}
	}

	for _, p := range w.Players {
		if p != shooter && p.Alive && p.Team != shooter.Team {
			if t, ok := rayCircle(ox, oy, dx, dy, p.Pos.X, p.Pos.Y, p.Radius, res.T); ok {
				res.Hit, res.T, res.Kind, res.Target = true, t, HitPlayer, p
			}
		}
	}

	res.X = ox + dx*res.T
	res.Y = oy + dy*res.T
	return res
}
