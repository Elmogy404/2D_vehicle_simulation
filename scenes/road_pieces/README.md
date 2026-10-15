# Modular road pieces

These authored scenes are the modular road-asset library used by the segmented city generator. The original procedural generator remains available as a separate choice in the simulation.

Open `scenes/road_piece_catalog.tscn` and run it (F6 in Godot) to see the complete sheet. Cyan dots mark port centers and red lines show the outward direction.

## Pieces

- `straight_2_lane`, `straight_4_lane`, `straight_6_lane`: straight segments. Lane counts are total lanes across both directions, not per direction.
- `straight_2_lane_crosswalk`, `straight_4_lane_crosswalk`: matching straight segments with a centered zebra crossing, paired stop lines, and one fixed signal anchor per approach. Their anchors can drive live traffic lights and pedestrians when the pieces are placed, but the current automatic generator does not select these centered-crosswalk straights.
- `turn_left`, `turn_right`: complete 90-degree two-lane connectors, including straight tangent approaches at both sockets.
- `t_junction`: four-lane north/south road with a two-lane east branch.
- `t_junction_2_lane`, `four_way_intersection_2_lane`: conventional two-lane neighborhood junctions used by the graph-first city generator.
- `four_way_intersection`: four approaches, four total lanes per approach.
- `u_turn_dead_end_bulb`: the bulb-style terminal used when an open road end cannot be joined cleanly; it has a two-lane approach into a circular turnaround bulb.
- `bulb_3_road_junction`, `bulb_4_road_junction`: circular paved hubs with three or four two-lane road arms and crosswalks at the approaches.
- `lane_transition_6_to_4`, `lane_transition_4_to_2`: separate funnel tapers. Each narrows symmetrically by dropping one outside lane per direction, with converging edges and merge hatching.

## Socket and metadata contract

Every scene uses `scripts/road_piece.gd`. `get_piece_spec()` returns the piece ID, lane width, sockets, traffic-signal anchors, crosswalks, and local drive paths. A socket's `position` is the centerline endpoint, `outward` points away from the piece, and `total_lanes` is the lane count at that exact socket. The lane scale is 90 simulation units. On the centered-crosswalk straights, `center_crosswalk` is at local `(0, 0)`; each signal anchor records its approach port, stop-line center, and fixed roadside light point.

Two sockets can be joined when their positions are aligned in world space, their outward vectors face opposite directions, and their lane counts match (or a later transition piece explicitly connects them). Signal and crosswalk anchors are authored from the same socket data rather than inferred separately.

## Segmented generator

`scenes/segment_road_generator_preview.tscn` uses these pieces to build a
seeded street grid centered on a four-way arterial hub. The generator plans
the street graph first, then places neighborhood T/four-way junctions, turn
corners, narrow local streets, lane transitions, and variable-length straight
pieces. Each straight segment draws its own asphalt, sidewalk, curb lines, lane
markings, sockets, and drive path; adjacent pieces meet at shared socket
positions. Some local streets are omitted to vary block shape while preserving
network connectivity; terminal branches use bulb turnarounds. Footprint checks
reject road overlap, and the requested piece budget is filled by subdividing
longer straight corridors. In the preview, **Up/Down** zoom and **WASD** pan the camera.

The current planner assigns two or four lanes to grid edges. The six-lane
straight and 6-to-4 funnel are catalog/test assets, not generated map pieces.

Run `scenes/segment_road_generator_preview.tscn` with F6 to inspect a 500-piece
map; **Up/Down** zoom and **WASD** pan. In the main simulation, choose either
**Original procedural network** or **Segmented city blocks · 200 pieces** in
the startup settings before generating a map. Segmented maps expose a sampled
road graph and center arterial route to the existing traffic, pedestrian,
traffic-light, minimap, player-spawn, and AI route-planning systems.
