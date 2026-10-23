"""Serializable statistics shared by evaluation, live status, and tests."""
from __future__ import annotations

import math
from statistics import mean


def success_interval(successes: int, count: int) -> list[float]:
    """Wilson 95% binomial interval; empty samples have no precision."""
    if count == 0:
        return [0.0, 1.0]
    z = 1.959963984540054
    p = successes / count
    divisor = 1 + z * z / count
    center = (p + z * z / (2 * count)) / divisor
    spread = z * math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) / divisor
    return [max(0.0, center - spread), min(1.0, center + spread)]


def summarize(outcomes: list[dict]) -> dict:
    if not outcomes:
        return {"episodes": 0}
    count = len(outcomes)
    result = {"episodes": count, "successes": sum(bool(x.get("success")) for x in outcomes)}
    for key, flag in (("success_rate", "success"), ("crash_rate", "crashed"), ("off_road_rate", "off_road"),
                      ("stall_rate", "stalled"), ("timeout_rate", "truncated"), ("turn_coverage", "turn_requirement_met")):
        result[key] = sum(bool(x.get(flag)) for x in outcomes) / count
    for key, field in (("mean_return", "return"), ("mean_steps", "steps"), ("mean_progress", "progress_fraction"),
                       ("mean_speed_kmh", "speed_kmh"), ("mean_route_turns", "route_turns")):
        result[key] = mean(float(x.get(field, 0.0)) for x in outcomes)
    result["success_interval"] = success_interval(result["successes"], count)
    return result


def summarize_evaluation(outcomes: list[dict]) -> dict:
    result = summarize(outcomes)
    result["stages"] = [dict(stage=stage, **summarize([x for x in outcomes if x["stage"] == stage])) for stage in range(8)]
    result["longest_stage_success_rate"] = result["stages"][7].get("success_rate", 0.0)
    result["longest_stage_turn_coverage"] = result["stages"][7].get("turn_coverage", 0.0)
    return result
