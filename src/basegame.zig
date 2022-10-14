const std = @import("std");
const zlm = @import("zlm");
const zg = @import("zero-graphics");
const main = @import("entrypoint.zig");
const wmb = @import("wmb.zig");

fn core() *zg.CoreApplication {
    return zg.CoreApplication.get();
}

pub const nullvector = zlm.vec3(0, 0, 0);
pub const vector = zlm.vec3;
pub const Vector3 = zlm.Vec3;

pub const Matrix4 = zlm.Mat4;

pub const Angle = struct {
    pub const zero = Angle{ .pan = 0, .tilt = 0, .roll = 0 };

    pan: f32,
    tilt: f32,
    roll: f32 = 0,
};

/// Shuts down the engine
pub fn exit() void {
    @"__implementation".quit_now = true;
}

////////////////////////////////////////////////
// Global behaviour system
////////////////////////////////////////////////

var global_behaviours: BehaviourSystem(mem, void) = .{};

pub fn attach(comptime Behaviour: type) *Behaviour {
    return global_behaviours.attach({}, Behaviour);
}

pub fn behaviour(comptime Behaviour: type) ?*Behaviour {
    return global_behaviours.behaviour(Behaviour);
}

pub fn detach(comptime Behaviour: type) void {
    return global_behaviours.detach(Behaviour);
}

////////////////////////////////////////////////
// Modules
////////////////////////////////////////////////

pub const time = struct {
    pub var step: f32 = 0;
    pub var total: f32 = 0;
};

pub const mem = struct {
    var backing: std.mem.Allocator = std.heap.c_allocator;

    pub fn create(comptime T: type) *T {
        return backing.create(T) catch oom();
    }

    pub fn destroy(ptr: anytype) void {
        backing.destroy(ptr);
    }

    pub fn alloc(comptime T: type, count: usize) []T {
        return backing.alloc(T, count) catch oom();
    }

    pub fn free(ptr: anytype) void {
        backing.free(ptr);
    }
};

pub const level = struct {
    var arena: std.heap.ArenaAllocator = undefined;
    var entities: std.TailQueue(Entity) = .{};
    var level_behaviours: BehaviourSystem(level, void) = .{};

    const WmbTextureLoader = struct {
        level: wmb.Level,
        index: usize,

        pub fn create(loader: @This(), rm: *zg.ResourceManager) !zg.ResourceManager.TextureData {
            const source: wmb.Texture = loader.level.textures[loader.index];

            var data = zg.ResourceManager.TextureData{
                .width = std.math.cast(u15, source.width) orelse return error.InvalidFormat,
                .height = std.math.cast(u15, source.height) orelse return error.InvalidFormat,
                .pixels = undefined,
            };

            const pixel_count = @as(usize, data.width) * @as(usize, data.height);

            data.pixels = try rm.allocator.alloc(u8, 4 * pixel_count);
            errdefer rm.allocator.free(data.pixels.?);

            switch (source.format) {
                .rgba_8888 => std.mem.copy(u8, data.pixels.?, source.data), // equal size
                .rgb_888 => {
                    var i: usize = 0;
                    while (i < pixel_count) : (i += 1) {
                        data.pixels.?[4 * i + 0] = source.data[3 * i + 0];
                        data.pixels.?[4 * i + 1] = source.data[3 * i + 1];
                        data.pixels.?[4 * i + 2] = source.data[3 * i + 2];
                        data.pixels.?[4 * i + 3] = 0xFF;
                    }
                },
                .rgb_565 => {
                    var i: usize = 0;
                    while (i < pixel_count) : (i += 1) {
                        const Rgb = packed struct {
                            r: u5,
                            g: u6,
                            b: u5,
                        };
                        const rgb = @bitCast(Rgb, source.data[2 * i ..][0..2].*);

                        data.pixels.?[4 * i + 0] = (@as(u8, rgb.b) << 3) | (rgb.b >> 2);
                        data.pixels.?[4 * i + 1] = (@as(u8, rgb.g) << 2) | (rgb.g >> 4);
                        data.pixels.?[4 * i + 2] = (@as(u8, rgb.r) << 3) | (rgb.r >> 2);
                        data.pixels.?[4 * i + 3] = 0xFF;
                    }
                },
                .dds => return error.InvalidFormat,
            }

            return data;
        }
    };

    const WmbGeometryLoader = struct {
        level: wmb.Level,
        block: wmb.Block,

        pub fn create(loader: @This(), rm: *zg.ResourceManager) !zg.ResourceManager.GeometryData {
            const Vertex = zg.ResourceManager.Vertex;
            const Mesh = zg.ResourceManager.Mesh;

            const block = loader.block;

            var data = zg.ResourceManager.GeometryData{
                .vertices = undefined, // []Vertex,
                .indices = undefined, // []u16,
                .meshes = undefined, // []Mesh,
            };

            data.indices = try rm.allocator.alloc(u16, 3 * block.triangles.len);
            errdefer rm.allocator.free(data.indices);

            data.vertices = try rm.allocator.alloc(Vertex, block.vertices.len);
            errdefer rm.allocator.free(data.vertices);

            for (block.vertices) |src_vtx, i| {
                data.vertices[i] = Vertex{
                    .x = src_vtx.position.x,
                    .y = src_vtx.position.y,
                    .z = src_vtx.position.z,

                    // TODO: Fill with correct data
                    .nx = 0,
                    .ny = 1,
                    .nz = 0,

                    .u = src_vtx.texture_coord.x,
                    .v = src_vtx.texture_coord.y,
                };
            }

            // pre-sort triangles so we can easily created
            // meshes based on the texture alone.
            std.sort.sort(wmb.Triangle, block.triangles, block, struct {
                fn lt(ctx: wmb.Block, lhs: wmb.Triangle, rhs: wmb.Triangle) bool {
                    const lhs_tex = ctx.skins[lhs.skin].texture;
                    const rhs_tex = ctx.skins[rhs.skin].texture;
                    return lhs_tex < rhs_tex;
                }
            }.lt);

            var meshes = std.ArrayList(Mesh).init(rm.allocator);
            defer meshes.deinit();

            if (block.triangles.len > 0) {
                var mesh: *Mesh = undefined;
                var current_texture: u16 = ~@as(u16, 0);

                for (block.triangles) |tris, i| {
                    const tex_index = block.skins[tris.skin].texture;
                    if (i == 0 or tex_index != current_texture) {
                        current_texture = tex_index;

                        var tex = rm.createTexture(.@"3d", WmbTextureLoader{
                            .level = loader.level,
                            .index = tex_index,
                        }) catch |err| blk: {
                            std.log.err("failed to decode texture: {s}", .{@errorName(err)});
                            break :blk null;
                        };

                        mesh = try meshes.addOne();
                        mesh.* = Mesh{
                            .offset = i,
                            .count = 0,
                            .texture = tex,
                        };
                    }

                    const indices = data.indices[3 * i ..][0..3];
                    indices.* = tris.indices;

                    mesh.count += 3;
                }
            }
            data.meshes = meshes.toOwnedSlice();

            return data;
        }
    };

    pub fn load(path: ?[]const u8) void {
        arena.deinit();
        arena = std.heap.ArenaAllocator.init(mem.backing);
        entities = .{};
        level_behaviours = .{};

        if (path) |real_path| {
            var level_dir = std.fs.cwd().openDir(std.fs.path.dirname(real_path) orelse ".", .{}) catch |err| panic(err);
            defer level_dir.close();

            var level_file = level_dir.openFile(std.fs.path.basename(real_path), .{}) catch |err| panic(err);
            defer level_file.close();

            var level_source = std.io.StreamSource{ .file = level_file };

            var level_data = wmb.load(
                level.arena.allocator(),
                &level_source,
                .{
                    .target_coordinate_system = .opengl,
                    .scale = 1.0 / 16.0,
                },
            ) catch |err| panic(err);

            for (level_data.blocks) |src_block| {
                const geom = core().resources.createGeometry(WmbGeometryLoader{
                    .level = level_data,
                    .block = src_block,
                }) catch |err| panic(err);

                const ent = entity.create(null, nullvector, null);
                ent.geometry = geom;
            }

            std.log.err("implement loading level file '{?}'", .{level_data.info});
        }
    }

    pub fn create(comptime T: type) *T {
        return arena.allocator().create(T) catch oom();
    }

    pub fn alloc(comptime T: type, count: usize) []T {
        return arena.allocator().alloc(T, count) catch oom();
    }

    pub fn destroy(ptr: anytype) void {
        arena.allocator().destroy(ptr);
    }

    pub fn free(ptr: anytype) void {
        arena.allocator().free(ptr);
    }

    pub fn attach(comptime Behaviour: type) *Behaviour {
        return level_behaviours.attach({}, Behaviour);
    }

    pub fn behaviour(comptime Behaviour: type) ?*Behaviour {
        return level_behaviours.behaviour(Behaviour);
    }

    pub fn detach(comptime Behaviour: type) void {
        return level_behaviours.detach(Behaviour);
    }
};

pub const entity = struct {
    pub fn create(file: ?[]const u8, position: Vector3, comptime Behaviour: ?type) *Entity {
        const ent = level.create(std.TailQueue(Entity).Node);
        ent.* = .{
            .data = Entity{
                .pos = position,
            },
        };

        if (file) |actual_file_path| {
            ent.data.geometry = @"__implementation".loadGeometry(actual_file_path) orelse panic("file not found!");
        }

        if (Behaviour) |ActualBehaviour| {
            _ = ent.data.attach(ActualBehaviour);
        }

        level.entities.append(ent);

        return &ent.data;
    }
};

pub const Entity = struct {
    const Behaviours = BehaviourSystem(level, *Entity);

    // public:
    pos: Vector3 = nullvector,
    scale: Vector3 = zlm.Vec3.one,
    rot: Angle = Angle.zero,

    user_data: [256]u8 = undefined,
    geometry: ?*zg.ResourceManager.Geometry = null,

    // private:
    behaviours: Behaviours = .{},

    pub fn destroy(e: *Entity) void {
        const node = @fieldParentPtr(std.TailQueue(Entity).Node, "data", e);
        level.entities.remove(node);
    }

    pub fn attach(ent: *Entity, comptime Behaviour: type) *Behaviour {
        return ent.behaviours.attach(ent, Behaviour);
    }

    pub fn behaviour(ent: *Entity, comptime Behaviour: type) ?*Behaviour {
        return ent.behaviours.behaviour(Behaviour);
    }

    pub fn detach(ent: *Entity, comptime Behaviour: type) void {
        return ent.behaviours.detach(Behaviour);
    }
};

pub const View = struct {
    pos: Vector3 = nullvector,
    rot: Angle = Angle.zero,
    arc: f32 = 60.0,

    znear: f32 = 0.1,
    zfar: f32 = 10_000.0,

    viewport: zg.Rectangle = zg.Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

pub var camera: View = .{};

pub const Key = zg.Input.Scancode;

pub const key = struct {
    var held_keys: std.enums.EnumSet(zg.Input.Scancode) = .{};
    var pressed_keys: std.enums.EnumSet(zg.Input.Scancode) = .{};
    var released_keys: std.enums.EnumSet(zg.Input.Scancode) = .{};

    /// returns true if the `key` is currently held down.
    pub fn held(key_code: zg.Input.Scancode) bool {
        return held_keys.contains(key_code);
    }

    /// returns true if the `key` is was pressed this frame.
    pub fn pressed(key_code: zg.Input.Scancode) bool {
        return pressed_keys.contains(key_code);
    }

    /// returns true if the `key` is was released this frame.
    pub fn released(key_code: zg.Input.Scancode) bool {
        return released_keys.contains(key_code);
    }
};

pub const mouse = struct {
    pub const Button = zg.Input.MouseButton;

    pub var position: zg.Point = zg.Point.zero;
    pub var delta: zg.Point = zg.Point.zero;

    var held_buttons: std.enums.EnumSet(Button) = .{};
    var pressed_buttons: std.enums.EnumSet(Button) = .{};
    var released_buttons: std.enums.EnumSet(Button) = .{};

    /// returns true if the `key` is currently held down.
    pub fn held(button_index: Button) bool {
        return held_buttons.contains(button_index);
    }

    /// returns true if the `key` is was pressed this frame.
    pub fn pressed(button_index: Button) bool {
        return pressed_buttons.contains(button_index);
    }

    /// returns true if the `key` is was released this frame.
    pub fn released(button_index: Button) bool {
        return released_buttons.contains(button_index);
    }
};

// Include when stage2 can async:

// pub fn waitForFrame() void {
//     var node = main.Scheduler.WaitNode{
//         .data = main.Scheduler.TaskInfo{
//             .frame = undefined,
//         },
//     };
//     suspend {
//         node.data.frame = @frame();
//         main.scheduler.appendWaitNode(&node);
//     }
// }

// pub const scheduler = struct {
//     //
// };

pub const mat = struct {
    pub fn forAngle(ang: Angle) Matrix4 {
        return zlm.Mat4.batchMul(&.{
            zlm.Mat4.createAngleAxis(Vector3.unitZ, zlm.toRadians(ang.roll)),
            zlm.Mat4.createAngleAxis(Vector3.unitX, zlm.toRadians(ang.tilt)),
            zlm.Mat4.createAngleAxis(Vector3.unitY, zlm.toRadians(ang.pan)),
        });
    }
};

pub const vec = struct {
    pub fn rotate(v: Vector3, ang: Angle) Vector3 {
        return v.transformDirection(mat.forAngle(ang));
    }

    pub fn forAngle(ang: Angle) Vector3 {
        const pan = zlm.toRadians(ang.pan);
        const tilt = zlm.toRadians(ang.tilt);
        return vector(
            @sin(pan) * @cos(tilt),
            -@sin(tilt),
            -@cos(pan) * @cos(tilt),
        );
    }
};

pub const screen = struct {
    pub var color: zg.Color = .{ .r = 0, .g = 0, .b = 0x80 };
};

pub const DefaultCamera = struct {
    // const Mode = enum {
    //     no_visualization,
    //     only_stats,
    //     with_objects,
    // };

    pub fn update(_: *@This()) void {
        if (key.pressed(.escape))
            exit();

        const fps_mode = mouse.held(.secondary);

        const velocity: f32 = if (key.held(.shift_left))
            10.0
        else
            2.5;

        if (key.held(.left))
            camera.rot.pan += 90 * time.step;
        if (key.held(.right))
            camera.rot.pan -= 90 * time.step;
        if (key.held(.page_up))
            camera.rot.tilt -= 90 * time.step;
        if (key.held(.page_down))
            camera.rot.tilt += 90 * time.step;

        if (fps_mode) {
            camera.rot.pan -= @intToFloat(f32, mouse.delta.x);
            camera.rot.tilt += @intToFloat(f32, mouse.delta.y);
        }

        const fwd = vec.forAngle(camera.rot).scale(velocity * time.step);
        const left = vec.rotate(vector(1, 0, 0), camera.rot).scale(velocity * time.step);

        if (key.held(.up) or (fps_mode and key.held(.w)))
            camera.pos = camera.pos.add(fwd);
        if (key.held(.down) or (fps_mode and key.held(.s)))
            camera.pos = camera.pos.sub(fwd);

        if (fps_mode and key.held(.a))
            camera.pos = camera.pos.add(left);
        if (fps_mode and key.held(.d))
            camera.pos = camera.pos.sub(left);
    }
};

/// do not use this!
/// it's meant for internal use of the engine
pub const @"__implementation" = struct {
    const game = @import("@GAME@");

    const Application = main;
    var quit_now = false;

    var geometry_cache: std.StringHashMapUnmanaged(*zg.ResourceManager.Geometry) = .{};
    var texture_cache: std.StringHashMapUnmanaged(*zg.ResourceManager.Texture) = .{};

    // pub var scheduler: Scheduler = undefined;

    var last_frame_time: i64 = undefined;
    var r2d: zg.Renderer2D = undefined;
    var r3d: zg.Renderer3D = undefined;

    pub fn init(app: *Application) !void {
        app.* = .{};

        r2d = try core().resources.createRenderer2D();
        r3d = try core().resources.createRenderer3D();

        mem.backing = core().allocator;
        level.arena = std.heap.ArenaAllocator.init(mem.backing);

        // scheduler = Scheduler.init();
        // defer scheduler.deinit();

        // Coroutine(game.main).start(.{});
        try game.main();

        last_frame_time = zg.milliTimestamp();
    }

    pub fn update(_: *Application) !bool {
        const timestamp = zg.milliTimestamp();
        defer last_frame_time = timestamp;

        time.total = @intToFloat(f32, timestamp) / 1000.0;
        time.step = @intToFloat(f32, timestamp - last_frame_time) / 1000.0;

        key.pressed_keys = .{};
        key.released_keys = .{};

        mouse.pressed_buttons = .{};
        mouse.released_buttons = .{};

        const prev_mouse_pos = mouse.position;
        while (zg.CoreApplication.get().input.fetch()) |event| {
            switch (event) {
                .quit => return false,

                .key_down => |key_code| {
                    key.pressed_keys.insert(key_code);
                    key.held_keys.insert(key_code);
                },

                .key_up => |key_code| {
                    key.released_keys.insert(key_code);
                    key.held_keys.remove(key_code);
                },

                .pointer_motion => |position| {
                    mouse.position = position;
                },

                .pointer_press => |button| {
                    mouse.pressed_buttons.insert(button);
                    mouse.held_buttons.insert(button);
                },
                .pointer_release => |button| {
                    mouse.released_buttons.insert(button);
                    mouse.held_buttons.remove(button);
                },

                .text_input => |input| {
                    _ = input;
                },
            }
        }

        mouse.delta = .{
            .x = mouse.position.x - prev_mouse_pos.x,
            .y = mouse.position.y - prev_mouse_pos.y,
        };

        // global update process
        {
            global_behaviours.updateAll({});
        }

        // level update process
        {
            level.level_behaviours.updateAll({});
        }

        // entity update process
        {
            var it = level.entities.first;
            while (it) |node| : (it = node.next) {
                const ent: *Entity = &node.data;

                ent.behaviours.updateAll(ent);
            }
        }

        // schedule coroutines
        {
            // scheduler.nextFrame();
        }

        if (quit_now)
            return false;

        r2d.reset();
        r3d.reset();

        // render all entities
        {
            var it = level.entities.first;
            while (it) |node| : (it = node.next) {
                const ent: *Entity = &node.data;

                if (ent.geometry) |geometry| {
                    const mat_pos = zlm.Mat4.createTranslation(ent.pos);
                    const mat_rot = mat.forAngle(ent.rot);
                    const mat_scale = zlm.Mat4.createScale(ent.scale.x, ent.scale.y, ent.scale.z);

                    const trafo = zlm.Mat4.batchMul(&.{
                        mat_scale,
                        mat_rot,
                        mat_pos,
                    });

                    try r3d.drawGeometry(geometry, trafo.fields);
                }
            }
        }

        return (quit_now == false);
    }

    pub fn render(_: *Application) !void {
        const gl = zg.gles;

        gl.clearColor(
            @intToFloat(f32, screen.color.r) / 255.0,
            @intToFloat(f32, screen.color.g) / 255.0,
            @intToFloat(f32, screen.color.b) / 255.0,
            @intToFloat(f32, screen.color.a) / 255.0,
        );
        gl.clearDepthf(1.0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const ss = core().screen_size;

        const aspect = @intToFloat(f32, ss.width) / @intToFloat(f32, ss.height);

        const camera_fwd = vec.rotate(vector(0, 0, -1), camera.rot);
        const camera_up = vec.rotate(vector(0, 1, 0), camera.rot);

        const projection_matrix = zlm.Mat4.createPerspective(
            zlm.toRadians(camera.arc),
            aspect,
            camera.znear,
            camera.zfar,
        );
        const view_matrix = zlm.Mat4.createLook(camera.pos, camera_fwd, camera_up);

        const camera_view_proj = zlm.Mat4.batchMul(&.{
            view_matrix,
            projection_matrix,
        });

        r3d.render(camera_view_proj.fields);

        r2d.render(ss);
    }

    pub fn deinit(_: *Application) void {
        {
            var iter = geometry_cache.keyIterator();
            while (iter.next()) |file_name| {
                mem.backing.free(file_name.*);
            }
        }
        {
            var iter = texture_cache.keyIterator();
            while (iter.next()) |file_name| {
                mem.backing.free(file_name.*);
            }
        }

        geometry_cache.deinit(mem.backing);
        texture_cache.deinit(mem.backing);
    }

    fn load3DTexture(path: []const u8) ?*zg.ResourceManager.Texture {
        const full_path = std.fs.cwd().realpathAlloc(mem.backing, path) catch |err| panic(err);
        const gop = texture_cache.getOrPut(mem.backing, full_path) catch oom();

        if (gop.found_existing) {
            mem.free(full_path);
            return gop.value_ptr.*;
        }

        var file_data = std.fs.cwd().readFileAlloc(
            mem.backing,
            full_path,
            1 << 30, // GB
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| panic(e),
        };

        var spec = zg.ResourceManager.DecodeImageData{
            .data = file_data,
        };

        gop.value_ptr.* = core().resources.createTexture(.@"3d", spec) catch |err| panic(err);

        return gop.value_ptr.*;
    }

    fn loadGeometry(path: []const u8) ?*zg.ResourceManager.Geometry {
        const full_path = std.fs.cwd().realpathAlloc(mem.backing, path) catch |err| panic(err);
        const gop = geometry_cache.getOrPut(mem.backing, full_path) catch oom();

        if (gop.found_existing) {
            mem.free(full_path);
            return gop.value_ptr.*;
        }

        var file_data = std.fs.cwd().readFileAlloc(
            mem.backing,
            full_path,
            1 << 30, // GB
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| panic(e),
        };

        const TextureLoader = struct {
            pub fn load(_: @This(), rm: *zg.ResourceManager, name: []const u8) !?*zg.ResourceManager.Texture {
                std.debug.assert(&core().resources == rm);
                return load3DTexture(name);
            }
        };

        var spec = zg.ResourceManager.Z3DGeometry(TextureLoader){
            .data = file_data,
            .loader = TextureLoader{},
        };

        gop.value_ptr.* = core().resources.createGeometry(spec) catch |err| panic(err);

        return gop.value_ptr.*;
    }
};

inline fn oom() noreturn {
    @panic("out of memory");
}

inline fn panic(val: anytype) noreturn {
    const T = @TypeOf(val);
    if (T == []const u8)
        @panic(val);
    switch (@typeInfo(T)) {
        .ErrorSet => if (val == error.OutOfMemory) oom() else std.debug.panic("unhandled error: {s}", .{@errorName(val)}),
        .Enum => std.debug.panic("unhandled error: {s}", .{@tagName(val)}),
        else => std.debug.panic("unhandled error: {any}", .{val}),
    }
}

// Include when stage2 can async:

// pub const Scheduler = struct {
//     pub const TaskInfo = struct {
//         frame: anyframe,
//     };
//     pub const Process = struct {};
//     pub const WaitList = std.TailQueue(TaskInfo);
//     pub const WaitNode = WaitList.Node;
//     pub const ProcList = std.TailQueue(Process);
//     pub const ProcNode = ProcList.Node;

//     current_frame: WaitList = .{},
//     next_frame: WaitList = .{},
//     process_list: ProcList = .{},

//     fn init() Scheduler {
//         return Scheduler{};
//     }

//     pub fn deinit(sched: *Scheduler) void {
//         sched.* = undefined;
//     }

//     pub fn appendWaitNode(sched: *Scheduler, node: *WaitNode) void {
//         sched.next_frame.append(node);
//     }

//     pub fn nextFrame(sched: *Scheduler) void {
//         while (sched.current_frame.popFirst()) |func| {
//             resume func.data.frame;
//         }

//         sched.current_frame = sched.next_frame;
//         sched.next_frame = .{};
//     }
// };

// fn Coroutine(func: anytype) type {
//     const Func = @TypeOf(func);
//     const info: std.builtin.Type.Fn = @typeInfo(Func).Fn;
//     const return_type = info.return_type orelse @compileError("Must be non-generic function");

//     switch (@typeInfo(return_type)) {
//         .ErrorUnion, .Void => {},
//         else => @compileError("Coroutines can't return values!"),
//     }

//     return struct {
//         const Coro = @This();
//         const Frame = @Frame(wrappedCall);

//         const ProcNode = struct {
//             process: Scheduler.ProcNode,
//             frame: Frame,
//             result: void,
//         };

//         fn wrappedCall(mem: *ProcNode, args: std.meta.ArgsTuple(Func)) void {
//             var inner_result = @call(.{}, func, args);
//             switch (@typeInfo(return_type)) {
//                 .ErrorUnion => inner_result catch |err| std.log.err("{s} failed with error {s}", .{
//                     @typeName(Coro),
//                     @errorName(err),
//                 }),
//                 .Void => {},
//                 else => @compileError("Coroutines can't return values!"),
//             }
//             scheduler.process_list.remove(&mem.process);
//             engine.mem.destroy(mem);
//         }

//         pub fn start(args: anytype) void {
//             const mem = engine.mem.create(ProcNode);

//             mem.* = .{
//                 .process = .{ .data = Scheduler.Process{} },
//                 .frame = undefined,
//                 .result = {},
//             };
//             scheduler.process_list.append(&mem.process);
//             _ = @asyncCall(std.mem.asBytes(&mem.frame), &mem.result, wrappedCall, .{ mem, args });
//         }
//     };
// }

const BehaviourID = enum(usize) { _ };

fn BehaviourSystem(comptime memory_module: type, comptime Context: type) type {
    return struct {
        const System = @This();

        const Instance = struct {
            update: std.meta.FnPtr(fn (context: Context, node: *Node) void),
            id: BehaviourID,
        };

        pub const List = std.TailQueue(Instance);
        pub const Node = List.Node;

        list: List = .{},

        pub fn attach(instance: *System, context: Context, comptime Behaviour: type) *Behaviour {
            if (instance.behaviour(Behaviour)) |oh_behave|
                return oh_behave;

            const Storage = BehaviourStorage(Behaviour);

            const Updater = struct {
                fn update(ctx: Context, node: *Node) void {
                    if (!@hasDecl(Behaviour, "update"))
                        return;
                    const storage = @fieldParentPtr(Storage, "node", node);
                    // void is used to differentiate between basic and context based update.
                    // as void as a nonsensical value to pass, we can distinct on that.
                    if (Context != void) {
                        Behaviour.update(ctx, &storage.data);
                    } else {
                        Behaviour.update(&storage.data);
                    }
                }
            };

            const storage: *Storage = memory_module.create(Storage);
            storage.* = Storage{
                .node = .{
                    .data = .{
                        .id = Storage.id(),
                        .update = Updater.update,
                    },
                },
                .data = undefined,
            };

            if (@hasDecl(Behaviour, "init")) {
                Behaviour.init(context, &storage.data);
            } else {
                // If no init function is present,
                // we use a default initalization.
                storage.data = Behaviour{};
            }

            instance.list.append(&storage.node);

            return &storage.data;
        }

        pub fn behaviour(instance: *System, comptime Behaviour: type) ?*Behaviour {
            const Storage = BehaviourStorage(Behaviour);

            var it = instance.list.first;
            while (it) |node| : (it = node.next) {
                if (node.data.id == Storage.id()) {
                    return &@fieldParentPtr(Storage, "node", node).data;
                }
            }
            return null;
        }

        pub fn updateAll(instance: *System, context: Context) void {
            var behave_it = instance.list.first;
            while (behave_it) |behave_node| : (behave_it = behave_node.next) {
                behave_node.data.update(context, behave_node);
            }
        }

        pub fn detach(instance: *System, comptime Behaviour: type) void {
            const Storage = BehaviourStorage(Behaviour);

            var it = instance.list;
            while (it) |node| : (it = node.next) {
                if (node.data == Storage.id()) {
                    instance.list.remove(node);

                    const storage = @fieldParentPtr(Storage, "node", node);

                    if (@hasDecl(Behaviour, "deinit")) {
                        storage.data.deinit();
                    }

                    memory_module.destroy(storage);

                    return;
                }
            }
        }

        fn BehaviourStorage(comptime Behaviour: type) type {
            return struct {
                var storage_id_buffer: u8 = 0;

                pub inline fn id() BehaviourID {
                    return @intToEnum(BehaviourID, @ptrToInt(&storage_id_buffer));
                }

                node: Node,
                data: Behaviour,
            };
        }
    };
}
