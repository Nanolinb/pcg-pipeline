class_name PCGOverlapSolver
extends RefCounted

static func solve(components: Array, dragged: Node3D = null, preserved: Node3D = null) -> Dictionary:
	var scales: Dictionary = {}
	for component in components:
		scales[component.get_instance_id()] = component.neighborhood_scale
	for target in components:
		if target == dragged:
			continue
		var allowed: float = target.neighborhood_scale if target == preserved else 1.0
		for influencer in components:
			if influencer == target or influencer.wall != target.wall or not _influences(influencer, target, dragged):
				continue
			var influencer_scale: float = influencer.neighborhood_scale
			var distance: float = target.wall.surface_distance(target.anchor, influencer.anchor)
			var required: float = influencer.definition.footprint_radius() * influencer.user_scale * influencer_scale + influencer.definition.overlap_gap
			var available: float = (distance - required) / (target.definition.footprint_radius() * target.user_scale)
			allowed = minf(allowed, clampf(available, 0.0, 1.0))
		scales[target.get_instance_id()] = allowed
	return scales

static func _influences(influencer: Node3D, target: Node3D, dragged: Node3D) -> bool:
	if influencer == dragged:
		return true
	if target == dragged:
		return false
	if influencer.definition.priority == target.definition.priority:
		return influencer.get_instance_id() < target.get_instance_id()
	return influencer.definition.priority > target.definition.priority
