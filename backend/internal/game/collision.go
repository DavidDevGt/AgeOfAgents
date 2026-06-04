package game

import "math"

// AABB es un rectángulo eje-alineado (muro u objeto del mapa).
type AABB struct {
	X, Y, W, H float64
}

// circleVsAABB devuelve el vector de empuje mínimo (push) para separar un
// círculo de un AABB, o ok=false si no se solapan. Usa el punto más cercano.
func circleVsAABB(cx, cy, r float64, b AABB) (px, py float64, ok bool) {
	nx := math.Max(b.X, math.Min(cx, b.X+b.W))
	ny := math.Max(b.Y, math.Min(cy, b.Y+b.H))
	dx, dy := cx-nx, cy-ny
	d2 := dx*dx + dy*dy
	if d2 >= r*r {
		return 0, 0, false
	}
	if d2 > 1e-9 {
		d := math.Sqrt(d2)
		push := r - d
		return dx / d * push, dy / d * push, true
	}
	// Centro dentro del rectángulo: empujar por el eje de menor penetración.
	left, right := cx-b.X, b.X+b.W-cx
	top, bottom := cy-b.Y, b.Y+b.H-cy
	min := math.Min(math.Min(left, right), math.Min(top, bottom))
	switch min {
	case left:
		return -(left + r), 0, true
	case right:
		return right + r, 0, true
	case top:
		return 0, -(top + r), true
	default:
		return 0, bottom + r, true
	}
}

// MoveAndSlide mueve una entidad circular por (dx,dy) resolviendo colisiones
// contra los muros eje por eje (deslizamiento) y la mantiene dentro de bounds.
func MoveAndSlide(pos *Vec, radius, dx, dy float64, walls []AABB, bounds AABB) {
	// Eje X
	pos.X += dx
	for i := range walls {
		if px, _, ok := circleVsAABB(pos.X, pos.Y, radius, walls[i]); ok {
			pos.X += px
		}
	}
	// Eje Y
	pos.Y += dy
	for i := range walls {
		if _, py, ok := circleVsAABB(pos.X, pos.Y, radius, walls[i]); ok {
			pos.Y += py
		}
	}
	// Límites de la arena.
	if pos.X < bounds.X+radius {
		pos.X = bounds.X + radius
	}
	if pos.Y < bounds.Y+radius {
		pos.Y = bounds.Y + radius
	}
	if pos.X > bounds.X+bounds.W-radius {
		pos.X = bounds.X + bounds.W - radius
	}
	if pos.Y > bounds.Y+bounds.H-radius {
		pos.Y = bounds.Y + bounds.H - radius
	}
}
