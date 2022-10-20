const std = @import("std");
const eng = @import("basegame");

pub fn main() !void {
    eng.DefaultCamera.vel_slow = 64.0;
    eng.DefaultCamera.vel_high = 256.0;

    eng.level.load("levels/future/future.wmb");
    // eng.level.load("levels/import-test/root.wmb");

    _ = eng.attach(eng.DefaultCamera);
    _ = eng.attach(eng.DebugPanels);

    // eng.level.load("levels/future/doorlft1.wmb");
    // eng.level.load("levels/wmb6-demo.wmb");

    // _ = eng.entity.create("terrain.z3d", eng.nullvector, null);

    // _ = eng.entity.create("levels/test.wmb", eng.vector(0, 0, 0), _actions.Spinner);
    // _ = eng.entity.create("levels/future/sign+5.tga", eng.vector(0, 0, 0), null);

    // const sprite = eng.entity.create("levels/future/arrows.tga", eng.vector(0, 0, 0), _actions.Spinner);
    // sprite.scale = eng.Vector3.all(0.01);

    // _ = player.attach(_actions.YBouncer);

    // var i: usize = 0;
    // while (i < 10) : (i += 1) {
    //     std.log.info("i = {}", .{i});
    //     eng.waitForFrame();
    // }

    // return error.Poop;
}

/// Exposing a global namespace "actions"
/// will allow the engine to actually instantiate
/// these actions in entities loaded from a level.
/// Every pub structure in here can be loaded.
pub const actions = struct {
    pub const FXA_LightBlink = struct {
        pub fn update(ent: *eng.Entity, _: *@This()) void {
            if (eng.key.held(.@"1")) {
                ent.scale = ent.scale.add(eng.Vector3.all(0.1 * eng.time.step));
            }
        }
    };

    pub const a = struct {
        pub fn update(ent: *eng.Entity, _: *@This()) void {
            if (eng.key.held(.@"2")) {
                ent.scale = ent.scale.add(eng.Vector3.all(0.1 * eng.time.step));
            }
        }
    };

    /// - The trigger that opens the door to the final room
    /// - The sprite before the locked room
    pub const ga = struct {
        pub fn update(ent: *eng.Entity, _: *@This()) void {
            if (eng.key.held(.@"3")) {
                ent.scale = ent.scale.add(eng.Vector3.all(0.1 * eng.time.step));
            }
        }
    };

    pub const @".wmb" = struct {
        pub fn update(ent: *eng.Entity, _: *@This()) void {
            if (eng.key.held(.@"3")) {
                ent.scale = ent.scale.add(eng.Vector3.all(0.1 * eng.time.step));
            }
        }
    };

    pub const Player = struct {
        health: u32 = 100,
        shield: u32 = 0,

        pub fn init(ent: *eng.Entity, p: *Player) void {
            p.* = Player{};
            ent.scale.y = 0.1;
            ent.scale.z = 0.1;
        }

        pub fn update(ent: *eng.Entity, p: *Player) void {
            _ = p;
            ent.rot.pan += 10.0 * eng.time.step;
        }
    };

    pub const YBouncer = struct {
        pub fn update(ent: *eng.Entity, _: *YBouncer) void {
            ent.pos.y = 3.0 * @sin(eng.time.total);
        }
    };

    pub const Spinner = struct {
        pub fn update(ent: *eng.Entity, _: *Spinner) void {
            ent.rot.pan += 10.0 * eng.time.step;
        }
    };
};