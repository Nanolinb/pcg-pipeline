class_name PCGMaterialAccess
extends RefCounted

static func library() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("MaterialLibrary") as Node
	return null
