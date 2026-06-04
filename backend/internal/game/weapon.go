package game

// weapon.go — definiciones de armas/loadouts (datos) e instancias con estado
// mutable (munición, recarga, cadencia). Puerto fiel del loadouts.lua +
// weapons.lua originales. La LÓGICA de fuego vive en world.go (necesita acceso
// al mundo: raycast, daño, proyectiles).

type WeaponType int

const (
	Hitscan WeaponType = iota
	Melee
	Projectile
)

// WeaponDef son datos inmutables compartidos por todas las instancias.
type WeaponDef struct {
	ID          string
	Name        string
	Type        WeaponType
	Damage      float64
	Range       float64
	MagSize     int // tamaño del cargador. -1 => munición infinita (cuchillo)
	Reserve     int // munición inicial/máxima en la reserva (0 si no aplica)
	ReloadTime  float64
	FireDelay   float64
	Auto        bool
	Spread      float64
	ADSMoveMult float64
	// melee
	Arc float64
	// projectile (humo)
	ThrowSpeed  float64
	Friction    float64
	Fuse        float64
	SmokeRadius float64
	SmokeTime   float64
	// color de la trazadora (para el cliente)
	TracerR, TracerG, TracerB float64
}

// Catálogo de armas (equivalente a Weapons{} en loadouts.lua).
var Weapons = map[string]*WeaponDef{
	"sniper": {
		ID: "sniper", Name: "Rifle de Precisión", Type: Hitscan,
		Damage: 95, Range: 1600, MagSize: 5, Reserve: 15, ReloadTime: 2.6, FireDelay: 1.1,
		Spread: 0, ADSMoveMult: 0.35, TracerR: 0.6, TracerG: 0.9, TracerB: 1.0,
	},
	"pistol": {
		ID: "pistol", Name: "Pistola", Type: Hitscan,
		Damage: 34, Range: 700, MagSize: 12, Reserve: 36, ReloadTime: 1.4, FireDelay: 0.16,
		Spread: 0.025, ADSMoveMult: 0.7, TracerR: 1.0, TracerG: 0.85, TracerB: 0.4,
	},
	"rifle": {
		ID: "rifle", Name: "Rifle de Asalto", Type: Hitscan,
		Damage: 22, Range: 950, MagSize: 30, Reserve: 90, ReloadTime: 2.0, FireDelay: 0.09,
		Auto: true, Spread: 0.045, ADSMoveMult: 0.55,
		TracerR: 1.0, TracerG: 0.7, TracerB: 0.3,
	},
	"knife": {
		ID: "knife", Name: "Cuchillo", Type: Melee,
		Damage: 100, Range: 48, Arc: 1.2, FireDelay: 0.5, MagSize: -1, ReloadTime: 0,
		TracerR: 0.9, TracerG: 0.9, TracerB: 0.9,
	},
	"smoke": {
		ID: "smoke", Name: "Granada de Humo", Type: Projectile,
		Damage: 0, MagSize: 1, ReloadTime: 0, FireDelay: 0.6,
		ThrowSpeed: 520, Friction: 2.8, Fuse: 1.2, SmokeRadius: 90, SmokeTime: 8.0,
		TracerR: 0.8, TracerG: 0.8, TracerB: 0.8,
	},
}

// LoadoutDef es un par simétrico [primaria, secundaria].
type LoadoutDef struct {
	Name      string
	Primary   string
	Secondary string
}

var Loadouts = []LoadoutDef{
	{Name: "Cazador", Primary: "sniper", Secondary: "knife"},
	{Name: "Asaltante", Primary: "rifle", Secondary: "smoke"},
	{Name: "Sigiloso", Primary: "pistol", Secondary: "knife"},
	{Name: "Bombardero", Primary: "pistol", Secondary: "smoke"},
}

// Weapon es una instancia con estado por jugador y ronda.
type Weapon struct {
	Def         *WeaponDef
	Ammo        int // balas en el cargador
	Reserve     int // balas en la reserva (mochila); se agota al recargar
	FireTimer   float64
	ReloadTimer float64
	Reloading   bool
}

func NewWeapon(def *WeaponDef) *Weapon {
	return &Weapon{Def: def, Ammo: def.MagSize, Reserve: def.Reserve}
}

func (w *Weapon) Reset() {
	w.Ammo = w.Def.MagSize
	w.Reserve = w.Def.Reserve
	w.FireTimer = 0
	w.ReloadTimer = 0
	w.Reloading = false
}

func (w *Weapon) Update(dt float64) {
	if w.FireTimer > 0 {
		w.FireTimer -= dt
		if w.FireTimer < 0 {
			w.FireTimer = 0
		}
	}
	if w.Reloading {
		w.ReloadTimer -= dt
		if w.ReloadTimer <= 0 {
			w.Reloading = false
			w.ReloadTimer = 0
			w.completeReload()
		}
	}
}

// completeReload transfiere de la reserva al cargador lo necesario para
// llenarlo, sin pasarse de lo disponible. Llamado al terminar la animación.
func (w *Weapon) completeReload() {
	need := w.Def.MagSize - w.Ammo
	if need > w.Reserve {
		need = w.Reserve // solo hay tanto en la mochila
	}
	if need > 0 {
		w.Ammo += need
		w.Reserve -= need
	}
}

func (w *Weapon) HasAmmo() bool { return w.Def.MagSize < 0 || w.Ammo > 0 }

func (w *Weapon) CanFire() bool {
	return w.FireTimer <= 0 && !w.Reloading && w.HasAmmo()
}

func (w *Weapon) StartReload() bool {
	d := w.Def
	// Bloquea si: ya recarga, arma infinita, no recargable, cargador lleno, o
	// reserva vacía (no hay balas que transferir).
	if w.Reloading || d.MagSize < 0 || d.ReloadTime <= 0 || w.Ammo >= d.MagSize || w.Reserve <= 0 {
		return false
	}
	w.Reloading = true
	w.ReloadTimer = d.ReloadTime
	return true
}

// Loadout es el par de armas instanciado para un jugador en una ronda.
type Loadout struct {
	Name      string
	Primary   *Weapon
	Secondary *Weapon
}

func BuildLoadout(def LoadoutDef) *Loadout {
	return &Loadout{
		Name:      def.Name,
		Primary:   NewWeapon(Weapons[def.Primary]),
		Secondary: NewWeapon(Weapons[def.Secondary]),
	}
}
