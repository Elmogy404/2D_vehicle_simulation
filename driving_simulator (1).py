"""Python-only driving sandbox. Run: python driving_simulator.py."""

from dataclasses import dataclass
from bisect import bisect_left
import math
import random
import time
import tkinter as tk


WORLD_LENGTH = 6500
CAR_WIDTH, CAR_LENGTH = 24, 46


@dataclass(frozen=True)
class RoadMap:
    name: str
    city: str
    width: int
    lanes: int
    amplitude: float
    frequency: float
    ground: str
    waterfront: bool = False
    complex_layout: bool = False

    def center(self, y):
        return 620 + self.amplitude * math.sin(y / self.frequency)

    def paths(self):
        if not self.complex_layout:
            return [Route([(self.center(y), y) for y in range(WORLD_LENGTH, -1, -20)])]
        if self.name == "Fouad Street":
            main = rounded([(700, 6500), (700, 5600), (250, 5600),
                            (250, 4650), (950, 4650), (950, 3900),
                            (500, 3900), (500, 3300), (780, 3300),
                            (780, 3650), (1250, 3650), (1250, 2450),
                            (700, 2450), (700, 100)])
            branches = [rounded([(700, 6000), (1150, 6000), (1150, 5100), (250, 5100)]),
                        rounded([(950, 4250), (100, 4250), (100, 2800), (1250, 2800)]),
                        rounded([(700, 1950), (200, 1950), (200, 850), (700, 850)])]
            return [Route(main)] + [Route(p) for p in branches]
        main = rounded([(620, 6500), (620, 5550), (1050, 5550),
                        (1050, 4500), (400, 4500), (400, 3700),
                        (900, 3700), (900, 3200), (650, 3200),
                        (650, 3500), (150, 3500), (150, 2300),
                        (650, 2300), (650, 100)])
        branches = [rounded([(620, 5900), (200, 5900), (200, 5000), (1050, 5000)]),
                    rounded([(400, 4100), (1250, 4100), (1250, 2750), (150, 2750)]),
                    rounded([(650, 1900), (1100, 1900), (1100, 950), (650, 950)])]
        return [Route(main)] + [Route(p) for p in branches]


def rounded(points, radius=115):
    """Round right-angle corners, retaining actual hairpins and branches."""
    result = [points[0]]
    for previous, corner, following in zip(points, points[1:], points[2:]):
        before = math.dist(previous, corner)
        after = math.dist(corner, following)
        radius_here = min(radius, before * 0.35, after * 0.35)
        a = tuple(c + (p - c) * radius_here / before for p, c in zip(previous, corner))
        b = tuple(c + (p - c) * radius_here / after for p, c in zip(following, corner))
        result.append(a)
        for i in range(1, 17):
            t = i / 16
            result.append(tuple((1-t)**2 * av + 2*(1-t)*t*cv + t*t*bv
                                for av, cv, bv in zip(a, corner, b)))
    result.append(points[-1])
    return result


class Route:
    def __init__(self, points):
        self.points = points
        self.segments = []
        self.grid = {}
        self.length = 0
        for a, b in zip(points, points[1:]):
            length = math.dist(a, b)
            if length:
                self.segments.append((a, b, self.length, length))
                index = len(self.segments)-1
                for gx in range(math.floor(min(a[0], b[0])/200), math.floor(max(a[0], b[0])/200)+1):
                    for gy in range(math.floor(min(a[1], b[1])/200), math.floor(max(a[1], b[1])/200)+1):
                        self.grid.setdefault((gx, gy), set()).add(index)
                self.length += length
        self.ends = [start+length for a, b, start, length in self.segments]

    def pose(self, distance, offset=0):
        distance = max(0, min(self.length, distance))
        a, b, start, length = self.segments[min(bisect_left(self.ends, distance), len(self.segments)-1)]
        dx, dy = (b[0]-a[0])/length, (b[1]-a[1])/length
        t = (distance-start)/length
        return (a[0]+(b[0]-a[0])*t-dy*offset,
                a[1]+(b[1]-a[1])*t+dx*offset, math.atan2(dx, -dy))

    def nearest(self, x, y, limit=None):
        best = (float('inf'), 0)
        if limit is None:
            candidates = range(len(self.segments))
        else:
            candidates = set()
            for gx in range(math.floor((x-limit)/200), math.floor((x+limit)/200)+1):
                for gy in range(math.floor((y-limit)/200), math.floor((y+limit)/200)+1):
                    candidates.update(self.grid.get((gx, gy), ()))
        for index in candidates:
            a, b, start, length = self.segments[index]
            t = max(0, min(1, ((x-a[0])*(b[0]-a[0])+(y-a[1])*(b[1]-a[1]))/length**2))
            distance = math.hypot(x-a[0]-(b[0]-a[0])*t, y-a[1]-(b[1]-a[1])*t)
            if distance < best[0]:
                best = distance, start+t*length
        return best


MAPS = (
    RoadMap("Salah Salem Street", "Cairo", 300, 6, 85, 640, "#c5b493"),
    RoadMap("Nile Corniche", "Cairo", 220, 4, 115, 780, "#c3b8a1", True),
    RoadMap("Alexandria Corniche", "Alexandria", 260, 4, 170, 1000,
            "#d5c5a5", True),
    RoadMap("El-Moez Street", "Cairo", 124, 2, 0, 1, "#bda78c", complex_layout=True),
    RoadMap("Fouad Street", "Alexandria", 144, 2, 0, 1, "#c9b69c", complex_layout=True),
)


@dataclass
class Car:
    x: float
    y: float
    angle: float = 0
    speed: float = 0
    color: str = "#f3b83f"
    route: object = None
    progress: float = 0
    direction: int = 1
    cruise: float = 0
    offset: float = 0

    def corners(self):
        sine, cosine = math.sin(self.angle), math.cos(self.angle)
        return [(self.x + dx * cosine - dy * sine,
                 self.y + dx * sine + dy * cosine)
                for dx, dy in ((-12, -23), (12, -23), (12, 23), (-12, 23))]


def overlaps(first, second):
    """Separating axis test for rotated car bodies."""
    a, b = first.corners(), second.corners()
    for polygon in (a, b):
        for index in range(2):
            p, q = polygon[index], polygon[index + 1]
            axis = (-(q[1] - p[1]), q[0] - p[0])
            one = [x * axis[0] + y * axis[1] for x, y in a]
            two = [x * axis[0] + y * axis[1] for x, y in b]
            if max(one) < min(two) or max(two) < min(one):
                return False
    return True


@dataclass(frozen=True)
class TrafficLight:
    route: Route
    progress: float
    direction: int
    group: int = 0
    phase_offset: float = 0

    def state(self, elapsed):
        phase = (elapsed + self.phase_offset - self.group*12) % 24
        return "green" if phase < 8 else "yellow" if phase < 10 else "red"


def junctions(routes):
    """Find branch joins and crossings, merging duplicate segment intersections."""
    points = []
    for i, first in enumerate(routes):
        for second in routes[i+1:]:
            for a, b, _, _ in first.segments:
                for c, d, _, _ in second.segments:
                    dx, dy = b[0]-a[0], b[1]-a[1]
                    ex, ey = d[0]-c[0], d[1]-c[1]
                    determinant = dx*ey-dy*ex
                    if abs(determinant) < 1e-9:
                        continue
                    t = ((c[0]-a[0])*ey-(c[1]-a[1])*ex)/determinant
                    u = ((c[0]-a[0])*dy-(c[1]-a[1])*dx)/determinant
                    if -1e-8 <= t <= 1+1e-8 and -1e-8 <= u <= 1+1e-8:
                        point = (a[0]+t*dx, a[1]+t*dy)
                        if all(math.dist(point, p) > 100 for p in points):
                            points.append(point)
    return points


class Simulation:
    """Player physics and deterministic waypoint traffic; no learning model."""

    def __init__(self, map_index=0):
        self.reset(map_index)

    def reset(self, map_index=None):
        if map_index is not None:
            self.map_index = map_index
        self.road = MAPS[self.map_index]
        self.routes = self.road.paths()
        self.player = Car(*self.routes[0].pose(140, self.road.width / 4))
        self.crashed = False
        self.finished = False
        self.distance = 0
        self.elapsed = 0
        self.lights = []
        if self.road.complex_layout:
            for point in junctions(self.routes):
                for index, route in enumerate(self.routes):
                    distance, progress = route.nearest(*point)
                    if distance > 2:
                        continue
                    for direction in (1, -1):
                        stop = progress-direction*(self.road.width/2+45)
                        if 60 < stop < route.length-60:
                            self.lights.append(TrafficLight(route, stop, direction,
                                                            0 if index == 0 else 1))
        else:
            for progress in (450, 2400, 4400):
                for direction in (1, -1):
                    self.lights.append(TrafficLight(self.routes[0], progress-direction*45,
                                                    direction, phase_offset=progress/150))
        rng = random.Random(100 + self.map_index)
        self.traffic = []
        colors = ("#d66c58", "#e8e3d6", "#5997b4", "#83936b")
        for route in self.routes:
            for distance in range(430, int(route.length)-200, 370):
                side = rng.choice((-1, 1))
                x, y, angle = route.pose(distance, side * (self.road.width/2-19))
                parked = Car(x, y, angle, color=rng.choice(colors))
                # Leave intersections and the inside of tight bends clear.
                if any(other is not route and other.nearest(x, y, self.road.width)[0] < self.road.width
                       for other in self.routes):
                    continue
                if abs(math.sin(route.pose(distance+35)[2]-route.pose(distance-35)[2])) > 0.08:
                    continue
                if self.on_road(parked) and not any(overlaps(parked, p) for p in self.traffic):
                    self.traffic.append(parked)
        self.moving = []
        for route in self.routes:
            for direction in (1, -1):
                for distance in range(650, int(route.length)-180, 1100):
                    offset = direction * (self.road.width/4 if self.road.width > 180
                                          else min(20, self.road.width/2-46))
                    x, y, angle = route.pose(distance, offset)
                    vehicle = Car(x, y, angle + (math.pi if direction < 0 else 0),
                                  color=rng.choice(colors), route=route, progress=distance,
                                  direction=direction, cruise=70 if self.road.complex_layout else 105,
                                  offset=offset)
                    if self.on_road(vehicle) and not any(overlaps(vehicle, p) for p in self.traffic+self.moving):
                        self.moving.append(vehicle)

    def on_road(self, car):
        return all(any(route.nearest(x, y, self.road.width/2)[0] <= self.road.width/2-2
                       for route in self.routes) for x, y in car.corners())

    def move_traffic(self, dt):
        # Stable ordering gives lower-index vehicles priority at intersections.
        for car in self.moving:
            ahead_angle = car.route.pose(car.progress+car.direction*60)[2]
            current_angle = car.route.pose(car.progress)[2]
            turning = abs(math.atan2(math.sin(ahead_angle-current_angle),
                                    math.cos(ahead_angle-current_angle))) > 0.25
            target_speed = car.cruise * (0.55 if turning else 1)
            remaining = car.route.length-car.progress if car.direction > 0 else car.progress
            if remaining < 3:
                # Re-enter at the same route's entrance only when it is clear.
                progress = 65 if car.direction > 0 else car.route.length-65
            else:
                progress = max(0, min(car.route.length, car.progress+car.direction*target_speed*dt))
                for light in self.lights:
                    if light.route is not car.route or light.direction != car.direction:
                        continue
                    # Keep the front bumper behind the painted stop line.
                    stop = light.progress-car.direction*(CAR_LENGTH/2+5)
                    gap = car.direction*(stop-car.progress)
                    if light.state(self.elapsed) != "green" and gap >= -0.01:
                        if car.direction*(progress-stop) >= 0:
                            progress = stop
                            target_speed = 0
            x, y, angle = car.route.pose(progress, car.offset)
            angle += math.pi if car.direction < 0 else 0
            candidate = Car(x, y, angle)
            blocked = not self.on_road(candidate)
            # Stop before obstacles, the player, or conflicting traffic.
            obstacles = self.traffic + self.moving + [self.player]
            for lookahead in (0, 25, 50):
                px, py, pa = car.route.pose(progress+car.direction*lookahead, car.offset)
                probe = Car(px, py, pa+(math.pi if car.direction < 0 else 0))
                if any(other is not car and abs(other.x-px) < 65 and abs(other.y-py) < 65
                       and overlaps(probe, other) for other in obstacles):
                    blocked = True
                    break
            car.speed = 0 if blocked else target_speed
            if not blocked:
                car.x, car.y, car.angle, car.progress = x, y, angle, progress

    def step(self, dt, keys):
        if self.crashed or self.finished:
            return
        dt = max(0, min(dt, 0.05))
        self.elapsed += dt
        car = self.player
        throttle = int("w" in keys) - int("s" in keys)
        if throttle:
            car.speed += throttle * 135 * dt
        else:
            drag = 45 * dt
            car.speed = math.copysign(max(0, abs(car.speed) - drag), car.speed)
        car.speed = max(-90, min(310, car.speed))
        steering = int("d" in keys) - int("a" in keys)
        steering_angle = 0.65 / (1 + abs(car.speed)/220)
        car.angle += steering * car.speed / 34 * math.tan(steering_angle) * dt
        car.x += math.sin(car.angle) * car.speed * dt
        car.y -= math.cos(car.angle) * car.speed * dt
        self.distance += abs(car.speed) * dt
        self.move_traffic(dt)
        if not self.on_road(car):
            self.crashed = True
        for other in self.traffic + self.moving:
            if abs(other.y - car.y) < 60 and overlaps(car, other):
                self.crashed = True
        if math.dist((car.x, car.y), self.routes[0].points[-1]) < 100 and not self.crashed:
            self.finished = True
        if self.crashed or self.finished:
            car.speed = 0


class DrivingWindow:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Egypt Streets | Python Driving Simulator")
        self.root.geometry("1100x780")
        self.root.minsize(800, 600)
        self.canvas = tk.Canvas(self.root, background="black", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.sim = Simulation()
        self.keys = set()
        self.last_time = time.perf_counter()
        self.root.bind("<KeyPress>", self.key_down)
        self.root.bind("<KeyRelease>", self.key_up)
        self.root.bind("<FocusOut>", lambda event: self.keys.clear())
        self.root.protocol("WM_DELETE_WINDOW", self.root.destroy)
        self.tick()

    def key_down(self, event):
        key = event.keysym.lower()
        # Windows keypad keycodes also work when Num Lock is off.
        keypad = {97+i: i for i in range(5)}
        aliases = {"1": 0, "2": 1, "3": 2, "kp_1": 0, "kp_2": 1,
                   "kp_3": 2, "kp_end": 0, "kp_down": 1, "kp_next": 2}
        aliases.update({"4": 3, "5": 4, "kp_4": 3, "kp_5": 4,
                        "kp_left": 3, "kp_begin": 4, "clear": 4})
        index = keypad.get(event.keycode, aliases.get(key))
        if index is not None:
            self.keys.clear()
            self.sim.reset(index)
        elif key == "r":
            self.keys.clear()
            self.sim.reset()
        elif key == "escape":
            self.root.destroy()
        else:
            self.keys.add(key)

    def key_up(self, event):
        self.keys.discard(event.keysym.lower())

    def tick(self):
        now = time.perf_counter()
        self.sim.step(now - self.last_time, self.keys)
        self.last_time = now
        self.draw()
        self.root.after(16, self.tick)

    def draw(self):
        c = self.canvas
        c.delete("all")
        width, height = c.winfo_width(), c.winfo_height()
        road, player = self.sim.road, self.sim.player
        camera_x = player.x - width / 2
        camera_y = player.y - height * 0.7

        def screen(x, y):
            return x - camera_x, y - camera_y

        c.create_rectangle(0, 0, width, height, fill="black", outline="")
        # Layer all sidewalks before all asphalt to keep junctions connected.
        for color, thickness in (("#ddd4bc", road.width+22), ("#414951", road.width)):
            for route in self.sim.routes:
                c.create_line(*[v for point in route.points for v in screen(*point)],
                              fill=color, width=thickness, capstyle=tk.ROUND,
                              joinstyle=tk.ROUND)
        for route in self.sim.routes:
            offsets = [(-road.width/2+lane*road.width/road.lanes)
                       for lane in range(1, road.lanes)]
            for offset in offsets:
                for distance in range(0, int(route.length), 65):
                    x, y, _ = route.pose(distance, offset)
                    if not (camera_x-80 < x < camera_x+width+80 and
                            camera_y-80 < y < camera_y+height+80):
                        continue
                    if any(other is not route and other.nearest(x, y, road.width/2)[0] < road.width/2
                           for other in self.sim.routes):
                        continue
                    points = [screen(*route.pose(d, offset)[:2])
                              for d in (distance, min(route.length, distance+30))]
                    c.create_line(*[v for point in points for v in point],
                                  fill="#e2bd66" if offset == 0 else "#c8cccd", width=2)
        for distance, label in ((self.sim.routes[0].length-65, "FINISH"), (200, "START")):
            route = self.sim.routes[0]
            a = screen(*route.pose(distance, -road.width/2)[:2])
            b = screen(*route.pose(distance, road.width/2)[:2])
            x, y, _ = route.pose(distance)
            sx, sy = screen(x, y)
            c.create_line(*a, *b, fill="white", width=4)
            c.create_text(sx, sy-20, text=label, fill="white", font=("Segoe UI", 12, "bold"))
        if road.complex_layout:
            # A route guide helps navigate the hairpin and optional branches.
            route = self.sim.routes[0]
            for distance in range(250, int(route.length), 220):
                x, y, angle = route.pose(distance, road.width/4)
                if camera_x-30 < x < camera_x+width+30 and camera_y-30 < y < camera_y+height+30:
                    sx, sy = screen(x, y)
                    c.create_line(sx-math.sin(angle)*14, sy+math.cos(angle)*14,
                                  sx+math.sin(angle)*14, sy-math.cos(angle)*14,
                                  fill="#66c9ba", width=2, arrow=tk.LAST)
        for car in self.sim.traffic + self.sim.moving + [player]:
            if camera_y-60 < car.y < camera_y+height+60 and camera_x-60 < car.x < camera_x+width+60:
                self.draw_car(car, screen)
        for light in self.sim.lights:
            self.draw_light(light, screen)
        if road.complex_layout:
            self.draw_minimap(width)
        c.create_rectangle(0, 0, width, 112, fill="#101b25", outline="")
        c.create_text(24, 22, anchor="w", text="EGYPT STREETS / DRIVING SANDBOX",
                      fill="#66c9ba", font=("Segoe UI", 10, "bold"))
        c.create_text(24, 53, anchor="w", text=f"{road.name}  ·  {road.city}",
                      fill="white", font=("Segoe UI", 21, "bold"))
        c.create_text(24, 88, anchor="w",
                      text="W / S  Accelerate, brake & reverse     A / D  Steer     R  Restart",
                      fill="#bfcbd3", font=("Segoe UI", 11))
        c.create_text(width - 24, 42, anchor="e", text=f"{abs(player.speed) * 0.18:.0f} km/h",
                      fill="#f3b83f", font=("Segoe UI", 24, "bold"))
        c.create_text(width - 24, 80, anchor="e",
                      text=f"Route: {max(0, min(100, self.sim.routes[0].nearest(player.x, player.y)[1] / self.sim.routes[0].length * 100)):.0f}%",
                      fill="#bfcbd3", font=("Segoe UI", 11))
        c.create_rectangle(0, height - 40, width, height, fill="#101b25", outline="")
        c.create_text(24, height - 20, anchor="w",
                      text="[1] Salah Salem   [2] Nile Corniche   [3] Alexandria Corniche   [4] El-Moez   [5] Fouad",
                      fill="white", font=("Segoe UI", 11))
        if self.sim.crashed or self.sim.finished:
            cx, cy = width / 2, height / 2
            c.create_rectangle(cx - 240, cy - 80, cx + 240, cy + 80,
                               fill="#101b25", outline="#f3b83f", width=2)
            c.create_text(cx, cy - 25,
                          text="Collision!" if self.sim.crashed else "Route completed!",
                          fill="#f3b83f", font=("Segoe UI", 28, "bold"))
            c.create_text(cx, cy + 25, text="Press R to restart or 1–3 to change street",
                          fill="white", font=("Segoe UI", 12))

    def draw_light(self, light, screen):
        road = self.sim.road
        a = screen(*light.route.pose(light.progress, light.direction*4)[:2])
        b = screen(*light.route.pose(light.progress, light.direction*(road.width/2-5))[:2])
        self.canvas.create_line(*a, *b, fill="white", width=4, tags="stop_line")
        x, y, _ = light.route.pose(light.progress, light.direction*(road.width/2+25))
        sx, sy = screen(x, y)
        c = self.canvas
        c.create_rectangle(sx-11, sy-30, sx+11, sy+30,
                           fill="#15191d", outline="#8d9ca6", width=2,
                           tags="traffic_light")
        state = light.state(self.sim.elapsed)
        for color, offset, bright in (("red", -18, "#ff4d4d"),
                                      ("yellow", 0, "#ffd34e"),
                                      ("green", 18, "#54e895")):
            c.create_oval(sx-7, sy+offset-7, sx+7, sy+offset+7,
                          fill=bright if state == color else "#30383e", outline="",
                          tags="traffic_light")

    def draw_car(self, car, screen):
        c = self.canvas
        sine, cosine = math.sin(car.angle), math.cos(car.angle)

        def shape(points, color, outline=""):
            coords = []
            for dx, dy in points:
                coords.extend(screen(car.x + dx * cosine - dy * sine,
                                     car.y + dx * sine + dy * cosine))
            c.create_polygon(coords, fill=color, outline=outline)

        shape([(-14, -20), (14, -20), (14, 23), (-14, 23)], "#20252a")
        shape([(-12, -19), (-9, -23), (9, -23), (12, -19),
               (12, 23), (-12, 23)], car.color, "#17222a")
        shape([(-9, -12), (9, -12), (8, -3), (-8, -3)], "#213e50")
        shape([(-8, 10), (8, 10), (9, 16), (-9, 16)], "#213e50")
        for x in (-8, 8):
            shape([(x - 2, -22), (x + 2, -22), (x + 2, -19), (x - 2, -19)], "#fff3bc")
            shape([(x - 2, 19), (x + 2, 19), (x + 2, 22), (x - 2, 22)], "#ef6c62")
        if car is self.sim.player:
            shape([(-5, -33), (5, -33), (0, -41)], "#66e4c4")

    def draw_minimap(self, width):
        c = self.canvas
        left, top, size = width-192, 130, 172
        c.create_rectangle(left-8, top-8, left+size+8, top+228,
                           fill="#101b25", outline="#647785")
        all_points = [p for route in self.sim.routes for p in route.points]
        min_x = min(p[0] for p in all_points)
        min_y = min(p[1] for p in all_points)
        span_x = max(p[0] for p in all_points)-min_x
        span_y = max(p[1] for p in all_points)-min_y
        scale = min(size/span_x, 188/span_y)

        def project(x, y):
            return left+(size-span_x*scale)/2+(x-min_x)*scale, top+12+(y-min_y)*scale

        for index, route in enumerate(self.sim.routes):
            c.create_line(*[v for p in route.points for v in project(*p)],
                          fill="#66c9ba" if index == 0 else "#8294a1", width=3)
        px, py = project(self.sim.player.x, self.sim.player.y)
        c.create_oval(px-4, py-4, px+4, py+4, fill="#f3b83f", outline="")
        fx, fy = project(*self.sim.routes[0].points[-1])
        c.create_oval(fx-3, fy-3, fx+3, fy+3, fill="white", outline="")
        c.create_text(left+size/2, top+213, text="Mint: route   Gray: branches",
                      fill="#bfcbd3", font=("Segoe UI", 8))

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    DrivingWindow().run()
