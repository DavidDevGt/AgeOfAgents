package game

// arena.go — DISEÑO TÁCTICO del mapa. Geometría simétrica de tres carriles
// (izquierdo · central con bandera · derecho) con dos tipos de cobertura:
//   * ALTA  -> muros de concreto indestructibles (bloquean visión, balas y paso)
//   * BAJA  -> parapetos de madera DESTRUIBLES (bloquean paso y balas hasta
//              romperse al agotar su HP)
//
// SIMETRÍA PERFECTA: todo se refleja sobre el eje vertical central x = cx, de
// modo que el equipo Azul (izquierda) y el Rojo (derecha) tengan exactamente
// las mismas oportunidades. Los elementos centrados en cx son auto-simétricos.

const coverMaxHP = 150.0

// Cover es una cobertura destruible (parapeto de madera). Bloquea movimiento y
// balas hitscan mientras Active; al llegar HP<=0 se rompe y sale de la colisión.
type Cover struct {
	Box    AABB
	HP     float64
	MaxHP  float64
	ID     int
	Active bool
}

// arenaBounds: área jugable simétrica de 1200x700, centrada en 1280x720.
var arenaBounds = AABB{X: 40, Y: 10, W: 1200, H: 700}

// buildArena devuelve los límites, los muros indestructibles y las coberturas
// destruibles, todos simétricos respecto al eje vertical central.
func buildArena() (AABB, []AABB, []Cover) {
	b := arenaBounds
	cx := b.X + b.W*0.5
	cy := b.Y + b.H*0.5

	// mirror refleja un rectángulo sobre el eje vertical x = cx.
	mirror := func(r AABB) AABB { return AABB{2*cx - r.X - r.W, r.Y, r.W, r.H} }

	// ---- Muros de concreto (cobertura ALTA) ----
	// Pilares centrales que flanquean la bandera (auto-simétricos: x = cx-22).
	walls := []AABB{
		{cx - 22, cy - 175, 44, 70},
		{cx - 22, cy + 105, 44, 70},
	}
	// Elementos del semiplano izquierdo; cada uno se añade junto a su reflejo.
	leftWalls := [...]AABB{
		{cx - 290, cy - 220, 40, 150}, // divisor de carril superior
		{cx - 290, cy + 70, 40, 150},  // divisor de carril inferior
		{b.X + 150, cy - 252, 140, 36}, // búnker superior junto al spawn
		{b.X + 150, cy + 216, 140, 36}, // búnker inferior junto al spawn
	}
	for _, r := range leftWalls {
		walls = append(walls, r, mirror(r))
	}

	// ---- Coberturas destruibles (cobertura BAJA) ----
	id := 0
	mk := func(r AABB) Cover {
		id++
		return Cover{Box: r, HP: coverMaxHP, MaxHP: coverMaxHP, ID: id, Active: true}
	}
	var covers []Cover
	pair := func(r AABB) { covers = append(covers, mk(r), mk(mirror(r))) }

	// Cajas de aproximación a la bandera (carril central).
	pair(AABB{cx - 172, cy - 112, 46, 46})
	pair(AABB{cx - 172, cy + 66, 46, 46})
	// Cajas de carril (peek lateral).
	pair(AABB{b.X + 360, cy - 24, 48, 48})
	// Cajas de salida cerca del spawn.
	pair(AABB{b.X + 232, cy - 150, 44, 44})
	pair(AABB{b.X + 232, cy + 106, 44, 44})

	// Cajas centradas en el eje (auto-simétricas): cobertura frontal a la bandera.
	covers = append(covers, mk(AABB{cx - 23, cy - 252, 46, 46}))
	covers = append(covers, mk(AABB{cx - 23, cy + 206, 46, 46}))

	return b, walls, covers
}
