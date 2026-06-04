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
