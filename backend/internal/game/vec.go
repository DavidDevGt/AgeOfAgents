package game

import "math"

// Vec es un vector 2D por valor. En Go el coste de copiar dos float64 es
// despreciable y evita el aliasing accidental, así que usamos semántica de
// valor en vez de la mutación in-place que necesitábamos en Lua para el GC.
type Vec struct {
	X, Y float64
}

func (a Vec) Add(b Vec) Vec      { return Vec{a.X + b.X, a.Y + b.Y} }
func (a Vec) Sub(b Vec) Vec      { return Vec{a.X - b.X, a.Y - b.Y} }
func (a Vec) Scale(s float64) Vec { return Vec{a.X * s, a.Y * s} }
func (a Vec) Dot(b Vec) float64  { return a.X*b.X + a.Y*b.Y }

func (a Vec) LenSq() float64 { return a.X*a.X + a.Y*a.Y }
func (a Vec) Len() float64   { return math.Hypot(a.X, a.Y) }

func (a Vec) DistSq(b Vec) float64 {
	dx, dy := a.X-b.X, a.Y-b.Y
	return dx*dx + dy*dy
}
func (a Vec) Dist(b Vec) float64 { return math.Hypot(a.X-b.X, a.Y-b.Y) }

// Normalized devuelve el vector unitario y la longitud original.
func (a Vec) Normalized() (Vec, float64) {
	l := a.Len()
	if l < 1e-9 {
		return Vec{}, 0
	}
	return Vec{a.X / l, a.Y / l}, l
}

func VecFromAngle(angle float64) Vec {
	return Vec{math.Cos(angle), math.Sin(angle)}
}

func (a Vec) AngleTo(b Vec) float64 {
	return math.Atan2(b.Y-a.Y, b.X-a.X)
}

// Lerp interpola linealmente: a + (b-a)*t.
func Lerp(a, b, t float64) float64 { return a + (b-a)*t }
