// Command server arranca el backend autoritativo de Gulag Arena.
//
//	go run ./cmd/server                 # 1v1 en :40000
//	go run ./cmd/server -mode 2         # 2v2
//	go run ./cmd/server -addr :40000    # dirección de escucha
//	go run ./cmd/server -debug          # logging de rondas/bajas + estadísticas
package main

import (
	"flag"
	"log"

	"gulagarena/internal/netcode"
)

func main() {
	addr := flag.String("addr", ":40000", "dirección UDP de escucha (host:puerto)")
	mode := flag.Int("mode", 1, "modo de juego: 1 = 1v1, 2 = 2v2")
	debug := flag.Bool("debug", false, "logging detallado (rondas, bajas, estadísticas de red)")
	flag.Parse()

	log.SetFlags(log.Ltime)

	srv, err := netcode.NewServer(*addr, *mode, *debug)
	if err != nil {
		log.Fatalf("no se pudo iniciar el servidor: %v", err)
	}
	srv.Run()
}
