## 自检：生成 18 层程序化图集并拼成一张总览图，方便肉眼校验
## 用法：godot --headless --path . --script res://scripts/test_atlas.gd
extends SceneTree


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var atlas := Atlas.new()
	var layers := atlas.build()
	var dt := Time.get_ticks_msec() - t0
	print("图集生成：%d 层，耗时 %d ms（每层 %.1f ms）" % [layers.size(), dt, float(dt) / layers.size()])

	var cell := Atlas.SIZE
	var pad := 6
	var cols := 6
	var rows := int(ceil(layers.size() / float(cols)))
	var sheet := Image.create_empty(cols * (cell + pad) + pad, rows * (cell + pad) + pad, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.06, 0.07, 0.09, 1.0))
	for i in layers.size():
		var cx := i % cols
		var cy := i / cols
		sheet.blit_rect(layers[i], Rect2i(0, 0, cell, cell), Vector2i(pad + cx * (cell + pad), pad + cy * (cell + pad)))

	DirAccess.make_dir_recursive_absolute("res://tmp")
	var path := "res://tmp/atlas_sheet.png"
	var err := sheet.save_png(path)
	if err != OK:
		push_error("保存失败：%d" % err)
		quit(1)
		return
	print("已保存 %s（%d×%d）" % [path, sheet.get_width(), sheet.get_height()])

	# 抽查各层 alpha 语义：立面层应有「大部分 0 + 少量 255」，其余层应全 255
	for i in layers.size():
		var img: Image = layers[i]
		var data := img.get_data()
		var zero := 0
		var full := 0
		var other := 0
		var k := 3
		while k < data.size():
			var a := data[k]
			if a == 0:
				zero += 1
			elif a == 255:
				full += 1
			else:
				other += 1
			k += 4
		print("  层 %2d alpha: 全透明 %5d 不透明 %5d 中间值 %5d" % [i, zero, full, other])
	quit(0)