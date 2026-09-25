## 音效引擎：全部波形在启动时用 GDScript 合成（零音频素材文件）
##
## 与 Web 版 WebAudio 实时合成的等价做法：
##  - 持续音（发动机 / 风噪 / 胎噪 / 砂石）生成 1 秒整周期无缝循环的 PCM，
##    用 AudioStreamPlayer.pitch_scale 与 volume_db 逐帧调制 → GPU/CPU 零额外负担。
##  - 一次性音（喇叭 / 碰撞 / 提示 / 点火）现场生成短 PCM，触发时播放。
## 无缝要点：循环长度固定 1 秒时，所有正弦分量频率取整数 Hz，则首尾自然衔接。
class_name AudioEngine
extends Node

const RATE := 22050
const LOOP_SECONDS := 1.0
const LOOP_N := int(RATE * LOOP_SECONDS)

var enabled := true
var volume := 0.8

var _engine: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _roll: AudioStreamPlayer   # 铺装路面胎噪
var _offroad: AudioStreamPlayer
var _skid: AudioStreamPlayer
var _horn: AudioStreamPlayer
var _once: AudioStreamPlayer   # 碰撞 / 提示 / 点火共用一个播放器
var _siren: AudioStreamPlayer

var _siren_on := false
var _horn_held := false
var _prev_handbrake := 0.0
var _brake_tick := 0.0


func _ready() -> void:
	_engine = _make_player(true)
	_wind = _make_player(true)
	_roll = _make_player(true)
	_offroad = _make_player(true)
	_skid = _make_player(true)
	_siren = _make_player(true)
	_horn = _make_player(false)
	_once = _make_player(false)

	_engine.stream = _gen_engine()
	_wind.stream = _gen_noise_loop(0.55, 0.0)
	_roll.stream = _gen_noise_loop(0.38, 0.35)
	_offroad.stream = _gen_noise_loop(0.22, 0.6)
	_skid.stream = _gen_noise_loop(0.85, 0.9)
	_siren.stream = _gen_siren()
	_horn.stream = _gen_horn()

	_engine.play()
	_wind.play()
	_roll.play()
	_offroad.play()
	_skid.play()
	_siren.play()
	for p in [_engine, _wind, _roll, _offroad, _skid, _siren]:
		p.volume_db = -60.0


func _make_player(loop: bool) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Master"
	add_child(p)
	if loop:
		p.autoplay = false
	return p


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		for p in [_engine, _wind, _roll, _offroad, _skid, _siren]:
			p.volume_db = -80.0


func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)


## 每帧调制（dt 秒）；速度单位 km/h
func update(dt: float, speed_kmh: float, rpm01: float, throttle: float, offroad: bool, handbrake: bool, skidding: bool, in_vehicle: bool) -> void:
	if not enabled:
		return
	var rpm := clampf(rpm01, 0.0, 1.0)
	var thr := clampf(throttle, 0.0, 1.0)
	var speed_n := clampf(maxf(0.0, speed_kmh) / 170.0, 0.0, 1.0)

	# 手刹"嗒"：一次性短音
	var hb := 1.0 if handbrake else 0.0
	if hb > 0.5 and _prev_handbrake <= 0.5:
		_brake_tick = 1.0
	elif _brake_tick > 0.0:
		_brake_tick = maxf(0.0, _brake_tick - dt * 14.0)
	_prev_handbrake = hb

	# 发动机：音高随转速，音量随转速与油门；车外整体压低
	_engine.pitch_scale = 0.62 + rpm * 1.9
	var eng_gain := (0.05 + rpm * 0.16 + thr * 0.09) * (0.85 if in_vehicle else 0.42)
	_engine.volume_db = linear_to_db(maxf(0.0001, eng_gain * volume))

	_wind.pitch_scale = 0.85 + speed_n * 0.5
	var wind_gain := speed_n * speed_n * (0.14 if in_vehicle else 0.05)
	_wind.volume_db = linear_to_db(maxf(0.0001, wind_gain * volume))

	_roll.pitch_scale = 0.8 + speed_n * 0.7
	var roll_gain := speed_n * (0.1 if not offroad else 0.0) * (0.9 if in_vehicle else 0.4)
	_roll.volume_db = linear_to_db(maxf(0.0001, roll_gain * volume))

	_offroad.pitch_scale = 0.8 + speed_n * 0.6
	var off_gain := (0.03 + speed_n * 0.1) if offroad else 0.0
	_offroad.volume_db = linear_to_db(maxf(0.0001, off_gain * volume))

	var skid_gain := ((0.08 + speed_n * 0.13) if skidding else 0.0) + _brake_tick * 0.05
	_skid.volume_db = linear_to_db(maxf(0.0001, skid_gain * volume))

	if _siren_on:
		_siren.volume_db = linear_to_db(maxf(0.0001, 0.16 * speed_n * volume + 0.06 * volume))
	else:
		_siren.volume_db = -80.0


## 喇叭（按住 / 松开）
func horn(down_now: bool) -> void:
	if down_now == _horn_held:
		return
	_horn_held = down_now
	if down_now and enabled:
		_horn.volume_db = linear_to_db(volume)
		_horn.play()


func crash(intensity: float) -> void:
	var k := clampf(intensity, 0.0, 1.0)
	if k <= 0.01 or not enabled:
		return
	_once.stream = _gen_crash(k)
	_once.volume_db = linear_to_db(volume)
	_once.play()


func ui_click() -> void:
	if not enabled:
		return
	_once.stream = _gen_blip(660.0, 0.07, 0.22)
	_once.volume_db = linear_to_db(volume * 0.7)
	_once.play()


func ignition() -> void:
	if not enabled:
		return
	_once.stream = _gen_blip(120.0, 0.35, 0.3)
	_once.volume_db = linear_to_db(volume * 0.8)
	_once.play()


func siren(on: bool) -> void:
	_siren_on = on


# ============================================================================
# 波形合成
# ============================================================================


func _make_stream(data: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = data.size() / 2
	return s


## 发动机：40Hz 基频 + 谐波 + 20Hz 气缸脉动（全部整数 Hz → 1 秒无缝）
func _gen_engine() -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(LOOP_N * 2)
	for i in LOOP_N:
		var t := float(i) / RATE
		var v := sin(TAU * 40.0 * t) * 0.50
		v += sin(TAU * 80.0 * t) * 0.30
		v += sin(TAU * 120.0 * t) * 0.17
		v += sin(TAU * 160.0 * t) * 0.10
		v += sin(TAU * 200.0 * t) * 0.05
		# 气缸脉动：让怠速有"突突"感
		v *= 0.72 + 0.28 * sin(TAU * 20.0 * t)
		# 一点机械噪声
		v += (randf() * 2.0 - 1.0) * 0.035
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 20000.0))
	return _make_stream(data, true)


## 噪声循环：一阶低通整形 + 首尾交叉淡化（多生成 fade 段再折叠回 1 秒，保证无缝）
func _gen_noise_loop(amount: float, lowpass: float) -> AudioStreamWAV:
	var fade := int(RATE * 0.25)
	var total := LOOP_N + fade
	var data := PackedByteArray()
	data.resize(total * 2)
	var prev := 0.0
	for i in total:
		var white := randf() * 2.0 - 1.0
		prev = prev * lowpass + white * (1.0 - lowpass)
		var v := prev * amount * 3.2
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 18000.0))
	for i in fade:
		var k := float(i) / fade
		var a := data.decode_s16(i * 2)
		var b := data.decode_s16((LOOP_N + i) * 2)
		data.encode_s16(i * 2, int(a * (1.0 - k) + b * k))
	data.resize(LOOP_N * 2)
	return _make_stream(data, true)


## 喇叭：双音（约 440 + 554 Hz）
func _gen_horn() -> AudioStreamWAV:
	var n := int(RATE * 0.6)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var env := minf(1.0, t * 40.0) * minf(1.0, (0.6 - t) * 12.0)
		var v := (sin(TAU * 440.0 * t) * 0.5 + sin(TAU * 554.0 * t) * 0.5) * env * 0.55
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 22000.0))
	return _make_stream(data, true)


## 警笛：1 秒内两段扫频（与循环无缝：起止频率相同）
func _gen_siren() -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(LOOP_N * 2)
	var phase := 0.0
	for i in LOOP_N:
		var t := float(i) / RATE
		var f := 620.0 + 260.0 * sin(TAU * t)
		phase += TAU * f / RATE
		var v := sin(phase) * 0.5
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 16000.0))
	return _make_stream(data, true)


## 碰撞：噪声爆发 + 低频闷响，随强度变长变亮
func _gen_crash(k: float) -> AudioStreamWAV:
	var dur := 0.22 + k * 0.22
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var prev := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t * (9.0 - k * 3.0))
		var white := randf() * 2.0 - 1.0
		prev = prev * (0.25 - k * 0.15) + white * (0.75 + k * 0.15)
		var thump := sin(TAU * (110.0 - t * 60.0) * t)
		var v := (prev * (0.45 + k * 0.5) + thump * (0.25 + k * 0.3)) * env
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 22000.0))
	return _make_stream(data, false)


## 短提示音
func _gen_blip(freq: float, dur: float, gain: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var env := minf(1.0, t * 60.0) * minf(1.0, (dur - t) * 18.0)
		var v := sin(TAU * freq * t) * env * gain
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 20000.0))
	return _make_stream(data, false)