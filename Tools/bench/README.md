# Measuring HoloFrame without wearing it

Everything here was used to find and fix real problems — input stalls, heat, yaw drift — with
the glasses lying on a desk. Build the helpers into a scratch directory; none of them is part
of the app.

```bash
B=/tmp/holoframe-bench; mkdir -p $B
S=Sources/HoloFrame
swiftc -O Tools/bench/taplist.swift -o $B/taplist
swiftc -O Tools/bench/pointer.swift -o $B/pointer
swiftc -O $S/XRealDevice.swift $S/Diagnostics.swift Tools/bench/imu-record/main.swift -o $B/imu-record
swiftc -O $S/HeadTracker.swift $S/AxisMap.swift $S/XRealDevice.swift Tools/bench/drift-sim/main.swift -o $B/drift-sim
```

## `taplist` — who is in the input path

Lists every event tap the window server knows about, whether it is **active** (holds input
until it answers) or listen-only, whether it is enabled, and the latency the window server has
measured for it. HoloFrame should show an active tap that is **off** except while right-⌥ is
held, and a listen-only tap that is on.

## `imu-record` — raw sensor data

```bash
$B/imu-record /tmp/static.bin 1800     # 30 minutes; runs alongside HoloFrame
```

Opens the glasses without seizing them, so HoloFrame keeps working, and never sends STOP. The
file is 10 doubles per sample: timestamp (ns), gyro xyz (deg/s), accel xyz (g), mag xyz
(gauss). `HOLOFRAME_RECORD=<path>` does the same from inside the app.

## `drift-sim` — yaw drift against a known truth

```bash
$B/drift-sim /tmp/static.bin 6                       # every scenario, 6 minutes each
MAG_KI=0 PRESET_ERR=0.15 $B/drift-sim /tmp/static.bin 6 reading
```

Takes a recording of the glasses lying still and superimposes a scripted head motion whose
orientation is known exactly: the implied rates are added to the real gyro samples, and gravity
and the real magnetic field are rotated into the moving head frame. The unmodified
`HeadTracker` is fed the result and its yaw compared with the truth. Scenarios: `still`,
`wobble` (holding still with natural sway), `glances`, `work` (glances plus sway), `reading`,
`asym` (slow out, fast back). Each runs with the gyro alone, with a clean field, and with 15%
and 35% hard-iron offsets.

Tuning overrides, all optional: `NOISE_LIMIT`, `DEADBAND`, `RATE_GATE`, `MAG_SLOW`, `MAG_FAST`,
`MAG_GAIN`, `MAG_KI`, and `PRESET_ERR` (start from a remembered bias off by this many deg/s on
z). Set them as separate words — in zsh, `env $v` with `v="A=1 B=2"` passes ONE argument and
silently runs the defaults.

## `perf-bench.sh` and `measure-load.sh` — what it costs

```bash
ROUNDS=3 CONFIGS="base nocapture cap30" Tools/bench/perf-bench.sh
```

Relaunches HoloFrame once per configuration with simulated head motion (`HOLOFRAME_SIM`), puts
the pointer on the canvas, lets it settle, then averages CPU for WindowServer, kernel_task and
HoloFrame and utilization for each GPU. Configurations are interleaved across rounds so heat
and background activity land on all of them equally. It moves the pointer and restarts the
app every minute — do not run it while using the machine, and do not run anything else heavy
alongside it.
