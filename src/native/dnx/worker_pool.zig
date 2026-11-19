//! The process-wide workers native DNx frame decodes share, and the row
//! buffers they reuse.
//!
//! A frame is short work: at 16 threads a 1080p frame is a few hundred
//! microseconds, so handing it out has to cost far less than that. A task is
//! published in a slot as a number of free seats; workers take a seat with one
//! compare-and-swap, with no lock to queue on. Workers start on first need,
//! spin briefly between tasks and then sleep on a futex. A task's caller
//! always works on it too, so a frame still finishes when no worker can start,
//! every slot is taken, or all workers are busy elsewhere.

const std = @import("std");

const Io = std.Io;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const max_workers = 63;
const max_tasks = 16;
const worker_stack_bytes = 1024 * 1024;
/// Tens of microseconds on a current desktop core: long enough to bridge the
/// gap between consecutive frames, short enough not to matter when idle.
const spin_limit = 4000;
const leave_spin_limit = 2000;
const buffer_slots = 32;

pub const buffer_alignment = 64;
pub const Buffer = []align(buffer_alignment) u8;

pub const Task = struct {
    /// Runs on the caller and each helper; returns when no work is left.
    run_fn: *const fn (*Task) void,
};

// A slot's state: free seats, workers inside, and whether the owner sleeps
// until they leave. Workers touch only the slot once they are done, so the
// task may live on its caller's stack.
const seat_mask: u32 = 0xff;
const active_one: u32 = 1 << 8;
const active_mask: u32 = 0xff << 8;
const owner_waiting: u32 = 1 << 31;

const Slot = struct {
    state: Atomic(u32) align(std.atomic.cache_line) = .init(0),
    task: Atomic(?*Task) = .init(null),
};

var slots: [max_tasks]Slot = @splat(.{});
/// Free seats over all slots: what idle workers watch.
var pending: Atomic(u32) align(std.atomic.cache_line) = .init(0);
var sleepers: Atomic(u32) align(std.atomic.cache_line) = .init(0);
/// Sleeping workers wait on this; it changes whenever work is published.
var wake_epoch: Atomic(u32) align(std.atomic.cache_line) = .init(0);
var worker_count: Atomic(u32) align(std.atomic.cache_line) = .init(0);
var spawn_mutex: Io.Mutex = .init;

/// The primitives are futex-based and need no scheduler from the instance.
fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Runs `task` on the calling thread and up to `helpers` workers, returning
/// once every one of them has left it.
pub fn run(task: *Task, helpers: u32) void {
    growWorkers(helpers);
    const seats = @min(helpers, worker_count.load(.acquire));
    const slot = if (seats > 0) claimSlot(task) else null;
    const owned = slot orelse {
        task.run_fn(task);
        return;
    };

    _ = owned.state.fetchAdd(seats, .release);
    _ = pending.fetchAdd(seats, .seq_cst);
    if (sleepers.load(.seq_cst) > 0) {
        _ = wake_epoch.fetchAdd(1, .seq_cst);
        io().futexWake(u32, &wake_epoch.raw, seats);
    }

    task.run_fn(task);
    retire(owned);
}

fn claimSlot(task: *Task) ?*Slot {
    for (&slots) |*slot| {
        if (slot.task.load(.monotonic) != null) continue;
        if (slot.task.cmpxchgStrong(null, task, .acquire, .monotonic) == null) return slot;
    }
    return null;
}

/// Withdraws the unclaimed seats and waits for the workers inside to leave.
fn retire(slot: *Slot) void {
    const before = slot.state.fetchAnd(~seat_mask, .acq_rel);
    const unclaimed = before & seat_mask;
    if (unclaimed > 0) _ = pending.fetchSub(unclaimed, .monotonic);

    var spins: u32 = 0;
    while (true) {
        const state = slot.state.load(.acquire);
        if (state & active_mask == 0) break;
        if (spins < leave_spin_limit) {
            spins += 1;
            std.atomic.spinLoopHint();
            continue;
        }
        const waiting = state | owner_waiting;
        if (state != waiting and slot.state.cmpxchgWeak(state, waiting, .acq_rel, .monotonic) != null) continue;
        io().futexWaitUncancelable(u32, &slot.state.raw, waiting);
    }
    slot.state.store(0, .monotonic);
    slot.task.store(null, .release);
}

fn growWorkers(helpers: u32) void {
    if (worker_count.load(.acquire) >= @min(helpers, max_workers)) return;
    const cores = Thread.getCpuCount() catch 1;
    const target: u32 = @intCast(@min(helpers, max_workers, cores -| 1));
    if (worker_count.load(.acquire) >= target) return;

    const pool_io = io();
    spawn_mutex.lockUncancelable(pool_io);
    defer spawn_mutex.unlock(pool_io);
    var count = worker_count.load(.monotonic);
    while (count < target) : (count += 1) {
        const thread = Thread.spawn(.{ .stack_size = worker_stack_bytes }, workerMain, .{count}) catch break;
        thread.detach();
        worker_count.store(count + 1, .release);
    }
}

/// Takes a free seat, leaving `slot` entered: its owner now waits for us.
fn takeSeat(slot: *Slot) ?*Task {
    var state = slot.state.load(.monotonic);
    while (state & seat_mask != 0) {
        state = slot.state.cmpxchgWeak(state, state - 1 + active_one, .acquire, .monotonic) orelse {
            _ = pending.fetchSub(1, .monotonic);
            return slot.task.load(.acquire);
        };
    }
    return null;
}

fn leave(slot: *Slot) void {
    const before = slot.state.fetchSub(active_one, .acq_rel);
    if (before & active_mask == active_one and before & owner_waiting != 0) {
        io().futexWake(u32, &slot.state.raw, 1);
    }
}

fn workerMain(index: u32) void {
    while (true) {
        var claimed = false;
        for (0..max_tasks) |offset| {
            const slot = &slots[(index + offset) % max_tasks];
            const task = takeSeat(slot) orelse continue;
            task.run_fn(task);
            leave(slot);
            claimed = true;
            break;
        }
        if (claimed) continue;

        var spins: u32 = 0;
        while (spins < spin_limit and pending.load(.acquire) == 0) : (spins += 1) std.atomic.spinLoopHint();
        if (pending.load(.acquire) != 0) continue;

        // Against `run`: it adds to `pending` before reading `sleepers`, we
        // the reverse, so one of the two sees the other. The epoch closes the
        // gap between our check and the wait.
        _ = sleepers.fetchAdd(1, .seq_cst);
        const epoch = wake_epoch.load(.seq_cst);
        if (pending.load(.seq_cst) == 0) io().futexWaitUncancelable(u32, &wake_epoch.raw, epoch);
        _ = sleepers.fetchSub(1, .monotonic);
    }
}

// Cached buffers carry their usable size in a header before the data.
const BufferHeader = extern struct { bytes: usize };
const buffer_header_bytes = buffer_alignment;

const BufferSlot = struct {
    header: Atomic(?*BufferHeader) align(std.atomic.cache_line) = .init(null),
};

var cached_buffers: [buffer_slots]BufferSlot = @splat(.{});

/// Where this thread starts looking: stacks differ, so threads rarely meet.
fn bufferStart() usize {
    return (@frameAddress() >> 16) % buffer_slots;
}

fn bufferOf(header: *BufferHeader) Buffer {
    const base: [*]align(buffer_alignment) u8 = @ptrCast(@alignCast(header));
    return (base + buffer_header_bytes)[0..header.bytes];
}

fn headerOf(buffer: Buffer) *BufferHeader {
    const base: [*]align(buffer_alignment) u8 = @alignCast(buffer.ptr - buffer_header_bytes);
    return @ptrCast(base);
}

fn freeBuffer(header: *BufferHeader) void {
    const base: [*]align(buffer_alignment) u8 = @ptrCast(@alignCast(header));
    std.heap.page_allocator.free(base[0 .. buffer_header_bytes + header.bytes]);
}

/// A buffer of at least `bytes`, reused from an earlier decode when one fits.
pub fn acquireBuffer(bytes: usize) std.mem.Allocator.Error!Buffer {
    const start = bufferStart();
    for (0..buffer_slots) |offset| {
        const slot = &cached_buffers[(start + offset) % buffer_slots];
        if (slot.header.load(.monotonic) == null) continue;
        const header = slot.header.swap(null, .acquire) orelse continue;
        if (header.bytes >= bytes) return bufferOf(header);
        freeBuffer(header);
        break;
    }
    const base = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(buffer_alignment), buffer_header_bytes + bytes);
    const header: *BufferHeader = @ptrCast(base.ptr);
    header.bytes = bytes;
    return bufferOf(header);
}

pub fn releaseBuffer(buffer: Buffer) void {
    const header = headerOf(buffer);
    const start = bufferStart();
    for (0..buffer_slots) |offset| {
        const slot = &cached_buffers[(start + offset) % buffer_slots];
        if (slot.header.load(.monotonic) != null) continue;
        if (slot.header.cmpxchgStrong(null, header, .release, .monotonic) == null) return;
    }
    freeBuffer(header);
}

const testing = std.testing;

const CountingTask = struct {
    task: Task = .{ .run_fn = runTask },
    next: Atomic(u32) = .init(0),
    done: Atomic(u32) = .init(0),
    total: u32,

    fn runTask(task: *Task) void {
        const self: *CountingTask = @fieldParentPtr("task", task);
        while (self.next.fetchAdd(1, .monotonic) < self.total) _ = self.done.fetchAdd(1, .monotonic);
    }
};

fn expectIdle() !void {
    for (&slots) |*slot| {
        // A slot in use by another test's thread would still be owned; these
        // tests finish their callers first.
        try testing.expectEqual(@as(u32, 0), slot.state.load(.acquire));
        try testing.expect(slot.task.load(.acquire) == null);
    }
    try testing.expectEqual(@as(u32, 0), pending.load(.acquire));
}

test "a task finishes all its work, with helpers and without" {
    for ([_]u32{ 0, 1, 7 }) |helpers| {
        var counting: CountingTask = .{ .total = 10_000 };
        run(&counting.task, helpers);
        try testing.expectEqual(@as(u32, 10_000), counting.done.load(.monotonic));
    }
    try expectIdle();
}

test "tasks from several threads run at once" {
    const Caller = struct {
        fn main(failed: *Atomic(bool)) void {
            for (0..200) |_| {
                var counting: CountingTask = .{ .total = 500 };
                run(&counting.task, 3);
                if (counting.done.load(.monotonic) != 500) failed.store(true, .monotonic);
            }
        }
    };
    var failed: Atomic(bool) = .init(false);
    var threads: [4]Thread = undefined;
    for (&threads) |*thread| thread.* = try Thread.spawn(.{}, Caller.main, .{&failed});
    for (threads) |thread| thread.join();
    try testing.expect(!failed.load(.monotonic));
    try expectIdle();
}

test "more callers than slots all finish" {
    const Caller = struct {
        fn main(failed: *Atomic(bool)) void {
            for (0..50) |_| {
                var counting: CountingTask = .{ .total = 2000 };
                run(&counting.task, 2);
                if (counting.done.load(.monotonic) != 2000) failed.store(true, .monotonic);
            }
        }
    };
    var failed: Atomic(bool) = .init(false);
    var threads: [max_tasks + 4]Thread = undefined;
    for (&threads) |*thread| thread.* = try Thread.spawn(.{}, Caller.main, .{&failed});
    for (threads) |thread| thread.join();
    try testing.expect(!failed.load(.monotonic));
    try expectIdle();
}

test "run waits for a helper that is still working" {
    if ((Thread.getCpuCount() catch 1) < 2) return error.SkipZigTest;
    const Slow = struct {
        task: Task = .{ .run_fn = runTask },
        entered: Atomic(u32) = .init(0),
        finished: Atomic(u32) = .init(0),

        fn runTask(task: *Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            if (self.entered.fetchAdd(1, .acq_rel) == 0) {
                // The caller: give a helper time to arrive, then leave first.
                var spins: u32 = 0;
                while (self.entered.load(.acquire) < 2 and spins < 200_000_000) : (spins += 1) std.atomic.spinLoopHint();
                return;
            }
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            _ = self.finished.fetchAdd(1, .release);
        }
    };
    var slow: Slow = .{};
    run(&slow.task, 1);
    try testing.expectEqual(slow.entered.load(.acquire) - 1, slow.finished.load(.acquire));
    try expectIdle();
}

test "workers wake from sleep for new work" {
    var first: CountingTask = .{ .total = 100 };
    run(&first.task, 3);
    testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    var second: CountingTask = .{ .total = 100_000 };
    run(&second.task, 3);
    try testing.expectEqual(@as(u32, 100_000), second.done.load(.monotonic));
    try expectIdle();
}

test "a released buffer is reused, and a larger request replaces it" {
    const first = try acquireBuffer(128);
    try testing.expect(first.len >= 128);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % buffer_alignment);
    releaseBuffer(first);
    const again = try acquireBuffer(64);
    try testing.expectEqual(first.ptr, again.ptr);
    releaseBuffer(again);
    const larger = try acquireBuffer(first.len + 4096);
    try testing.expect(larger.len >= first.len + 4096);
    releaseBuffer(larger);
}
