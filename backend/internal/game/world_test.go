package game

import (
	"math"
	"testing"
)

const dt = 1.0 / 60

func TestSymmetricLoadout(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	if !w.Match.HasLoadout {
		t.Fatal("debe asignarse un loadout")
	}
	for _, p := range w.Players {
		if p.Loadout.Name != w.Match.CurrentLoadout.Name {
			t.Fatalf("loadout asimétrico: %s vs %s", p.Loadout.Name, w.Match.CurrentLoadout.Name)
		}
	}
}

func TestDamageAndElimination(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	p1, p2 := w.Players[0], w.Players[1]
	for i := 0; i < 10 && p2.Alive; i++ {
		w.applyDamage(p2, 20, p1, "rifle")
	}
	if p2.Alive {
		t.Fatal("p2 debería estar muerto")
	}
	if p2.HP != 0 {
		t.Fatalf("HP no se satura en 0: %v", p2.HP)
	}
	w.Match.Update(dt, w)
	if w.Match.Phase != "ended" || w.Match.RoundWinner != 1 {
		t.Fatalf("equipo 1 debe ganar por eliminación, phase=%s winner=%d",
			w.Match.Phase, w.Match.RoundWinner)
	}
}

func TestOvertimeCapture(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	w.Match.RoundTime = 0.5
	for i := 0; i < 60; i++ {
		w.Match.Update(dt, w)
	}
	if w.Match.Phase != "overtime" {
		t.Fatalf("debe entrar en overtime, phase=%s", w.Match.Phase)
	}
	if !w.Match.Flag.Active {
		t.Fatal("bandera debe activarse en overtime")
	}
	f := w.Match.Flag
	w.Players[0].Pos = Vec{f.X, f.Y}
	w.Players[1].Pos = Vec{f.X + 600, f.Y}
	for i := 0; i < int(3.2/dt); i++ {
		w.Match.Update(dt, w)
	}
	if w.Match.Phase != "ended" || w.Match.RoundWinner != 1 {
		t.Fatalf("captura limpia debe ganar la ronda, phase=%s winner=%d",
			w.Match.Phase, w.Match.RoundWinner)
	}
}

func TestContestedCaptureBlocks(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	w.Match.RoundTime = 0.1
	for i := 0; i < 20; i++ {
		w.Match.Update(dt, w)
	}
	f := w.Match.Flag
	w.Players[0].Pos = Vec{f.X, f.Y}
	w.Players[1].Pos = Vec{f.X, f.Y} // ambos dentro => disputado
	for i := 0; i < int(4/dt); i++ {
		w.Match.Update(dt, w)
	}
	if w.Match.Phase != "overtime" {
		t.Fatalf("captura disputada no debe terminar la ronda, phase=%s", w.Match.Phase)
	}
	if w.Match.CaptureProgress != 0 {
		t.Fatalf("progreso debe reiniciarse en disputa: %v", w.Match.CaptureProgress)
	}
}

func TestOvertimeSuddenDeath(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	w.Match.RoundTime = 0.1
	for i := 0; i < 20; i++ {
		w.Match.Update(dt, w)
	}
	if w.Match.Phase != "overtime" {
		t.Fatalf("debe estar en overtime, phase=%s", w.Match.Phase)
	}
	// Ambos lejos de la bandera; equipo 2 con más vida => debe ganar al expirar.
	f := w.Match.Flag
	w.Players[0].Pos = Vec{f.X - 600, f.Y}
	w.Players[1].Pos = Vec{f.X + 600, f.Y}
	w.Players[0].HP = 40
	w.Players[1].HP = 90
	for i := 0; i < int(w.Match.OvertimeDuration/dt)+10 && w.Match.Phase == "overtime"; i++ {
		w.Match.Update(dt, w)
	}
	if w.Match.Phase != "ended" {
		t.Fatal("el tope de overtime debe terminar la ronda (anti-estancamiento)")
	}
	if w.Match.RoundWinner != 2 {
		t.Fatalf("muerte súbita debe ganarla el equipo con más vida (2), winner=%d", w.Match.RoundWinner)
	}
}

func TestReserveAmmoReload(t *testing.T) {
	rifle := NewWeapon(Weapons["rifle"]) // 30 / 90
	if rifle.Ammo != 30 || rifle.Reserve != 90 {
		t.Fatalf("estado inicial 30/90 esperado, got %d/%d", rifle.Ammo, rifle.Reserve)
	}

	// Gasta 10 balas y recarga: deben transferirse 10 desde la reserva.
	rifle.Ammo = 20
	if !rifle.StartReload() {
		t.Fatal("debería poder recargar con cargador parcial y reserva > 0")
	}
	rifle.ReloadTimer = 0
	rifle.completeReload()
	if rifle.Ammo != 30 || rifle.Reserve != 80 {
		t.Fatalf("tras recargar 10 esperaba 30/80, got %d/%d", rifle.Ammo, rifle.Reserve)
	}

	// Cargador lleno: StartReload no hace nada.
	if rifle.StartReload() {
		t.Fatal("no debe recargar con el cargador lleno")
	}

	// Reserva parcial: solo transfiere lo que queda.
	rifle.Ammo = 5
	rifle.Reserve = 7
	rifle.completeReload()
	if rifle.Ammo != 12 || rifle.Reserve != 0 {
		t.Fatalf("reserva parcial: esperaba 12/0, got %d/%d", rifle.Ammo, rifle.Reserve)
	}

	// Reserva a 0: recarga bloqueada aunque el cargador esté incompleto.
	rifle.Ammo = 5
	if rifle.StartReload() {
		t.Fatal("no debe recargar con reserva vacía")
	}

	// El cuchillo (munición infinita) nunca recarga.
	knife := NewWeapon(Weapons["knife"])
	if knife.StartReload() {
		t.Fatal("el cuchillo no debe recargar")
	}
}

func TestArenaSymmetry(t *testing.T) {
	_, walls, covers := buildArena()
	b := arenaBounds
	cx := b.X + b.W*0.5
	// Cada muro debe tener su reflejo exacto sobre el eje vertical central.
	mirrored := func(list []AABB, r AABB) bool {
		want := AABB{2*cx - r.X - r.W, r.Y, r.W, r.H}
		for _, o := range list {
			if o == want {
				return true
			}
		}
		return false
	}
	for _, r := range walls {
		if !mirrored(walls, r) {
			t.Fatalf("muro sin reflejo simétrico: %+v", r)
		}
	}
	coverBoxes := make([]AABB, len(covers))
	for i, c := range covers {
		coverBoxes[i] = c.Box
		if c.HP != coverMaxHP || !c.Active || c.ID == 0 {
			t.Fatalf("cobertura mal inicializada: %+v", c)
		}
	}
	for _, c := range covers {
		if !mirrored(coverBoxes, c.Box) {
			t.Fatalf("cobertura sin reflejo simétrico: %+v", c.Box)
		}
	}
}

func TestCoverDestructionAndReset(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	if len(w.Covers) == 0 {
		t.Fatal("debe haber coberturas")
	}
	solidsFull := len(w.Solids)

	// Destruye la cobertura 0 con daño suficiente.
	idx := 0
	id := w.Covers[idx].ID
	w.damageCover(idx, 100)
	if !w.Covers[idx].Active || w.Covers[idx].HP != 50 {
		t.Fatalf("daño parcial mal aplicado: %+v", w.Covers[idx])
	}
	w.damageCover(idx, 100) // total acumulado 200 > 150
	if w.Covers[idx].Active {
		t.Fatal("la cobertura debe romperse al llegar a 0")
	}
	if len(w.Breaks) != 1 || w.Breaks[0].ID != id {
		t.Fatalf("debe emitirse un BreakEvent con el id correcto: %+v", w.Breaks)
	}
	if len(w.Solids) != solidsFull-1 {
		t.Fatalf("la cobertura rota debe salir de Solids: %d vs %d", len(w.Solids), solidsFull-1)
	}

	// Una bala dirigida a esa caja ya no debe detenerse en ella.
	c := w.Covers[idx].Box
	ox := c.X - 50
	oy := c.Y + c.H/2
	hit := w.Cast(ox, oy, 1, 0, 2000, w.Players[0], false)
	if hit.Hit && hit.Kind == HitCover && hit.CoverIdx == idx {
		t.Fatal("la bala no debe chocar con una cobertura destruida")
	}

	// Nueva ronda restaura todas las coberturas.
	w.Match.StartRound(w)
	if !w.Covers[idx].Active || w.Covers[idx].HP != coverMaxHP {
		t.Fatalf("StartRound debe restaurar la cobertura: %+v", w.Covers[idx])
	}
	if len(w.Solids) != solidsFull {
		t.Fatalf("Solids debe restaurarse al completo: %d vs %d", len(w.Solids), solidsFull)
	}
}

func TestBulletBlockedByCover(t *testing.T) {
	w := NewWorld(1)
	w.Match.StartRound(w)
	c := w.Covers[0].Box
	// Disparo horizontal que cruza el centro de la caja: debe golpearla.
	ox := c.X - 60
	oy := c.Y + c.H/2
	hit := w.Cast(ox, oy, 1, 0, 2000, w.Players[0], false)
	if !hit.Hit || hit.Kind != HitCover {
		t.Fatalf("la bala debe impactar la cobertura activa, got hit=%v kind=%d", hit.Hit, hit.Kind)
	}
	if hit.X > c.X+1 {
		t.Fatalf("el impacto debe quedarse en la cara frontal de la caja (x≈%.1f), got %.1f", c.X, hit.X)
	}
}

func TestFullMatchWithBots(t *testing.T) {
	w := NewWorld(2)
	w.Start() // arranca: intro -> active...
	rounds := 0
	prevRW := -1
	for i := 0; i < 60*240 && !w.Match.MatchOver; i++ {
		w.Step(dt)
		if w.GamePhase == "roundend" && w.Match.RoundWinner != prevRW {
			rounds++
			prevRW = w.Match.RoundWinner
		} else if w.GamePhase != "roundend" {
			prevRW = -1
		}
	}
	if !w.Match.MatchOver {
		t.Fatalf("la partida de bots debería terminar; marcador %d-%d",
			w.Match.Scores[0], w.Match.Scores[1])
	}
	if w.Match.Scores[0]+w.Match.Scores[1] < 4 {
		t.Fatalf("muy pocas rondas resueltas: %d-%d", w.Match.Scores[0], w.Match.Scores[1])
	}
	t.Logf("Partida terminada %d-%d, ganador equipo %d",
		w.Match.Scores[0], w.Match.Scores[1], w.Match.MatchWinner)
	_ = math.Pi
}
