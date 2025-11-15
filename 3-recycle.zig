const std = @import("std");

const Header = struct {
    len: usize,
    free: bool,
};

const header_alignment = std.mem.Alignment.of(Header);

const AllocateurRecycle = struct {
    buffer: []u8,
    next: usize,

    /// Crée un allocateur à recyclage gérant la zone de mémoire délimitée
    /// par la tranche `buffer`.
    fn init(buffer: []u8) AllocateurRecycle {
        return .{
            .buffer = buffer,
            .next = 0,
        };
    }

    /// Retourne l’interface générique d’allocateur correspondant à
    /// cet allocateur à recyclage.
    fn allocator(self: *AllocateurRecycle) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }

    /// Tente d'allouer un bloc de mémoire de `len` octets dont l'adresse
    /// est alignée suivant `alignment`. Retourne un pointeur vers le début
    /// du bloc alloué, ou `null` pour indiquer un échec d'allocation.
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;

        const self: *AllocateurRecycle = @ptrCast(@alignCast(ctx));

        const align_value: usize = @as(usize, 1) << @intFromEnum(alignment);
        const header_align_value: usize = @as(usize, 1) << @intFromEnum(header_alignment);

        // Étape 1: Chercher un bloc libre réutilisable
        var pos: usize = 0;
        while (pos < self.next) {
            // Trouver le début du header aligné
            const header_start = std.mem.alignForward(usize, pos, header_align_value);

            if (header_start + @sizeOf(Header) > self.next) break;

            const header_ptr: *Header = @ptrCast(@alignCast(&self.buffer[header_start]));

            // Calculer où commencent les données
            const data_start_unaligned = header_start + @sizeOf(Header);
            const data_start = std.mem.alignForward(usize, data_start_unaligned, align_value);

            // Si ce bloc est libre et assez grand
            if (header_ptr.free and header_ptr.len >= len) {
                // Réutiliser ce bloc
                header_ptr.free = false;
                header_ptr.len = len;

                return self.buffer[data_start .. data_start + len].ptr;
            }

            // Avancer à la prochaine allocation
            const data_end = data_start + header_ptr.len;
            pos = data_end;
        }

        // Étape 2: Aucun bloc libre trouvé, allouer à la fin

        // Aligner pour le Header
        const header_start = std.mem.alignForward(usize, self.next, header_align_value);

        // Position après le header
        const data_start_unaligned = header_start + @sizeOf(Header);

        // Aligner pour les données
        const data_start = std.mem.alignForward(usize, data_start_unaligned, align_value);

        // Fin de l'allocation
        const data_end = data_start + len;

        // Vérifier si on dépasse le buffer
        if (data_end > self.buffer.len) {
            return null;
        }

        // Créer et initialiser le header
        const header_ptr: *Header = @ptrCast(@alignCast(&self.buffer[header_start]));
        header_ptr.* = Header{
            .len = len,
            .free = false,
        };

        // Mettre à jour next
        self.next = data_end;

        // Retourner le pointeur vers les données
        return self.buffer[data_start..data_end].ptr;
    }

    /// Récupère l'en-tête associé à l'allocation débutant à l'adresse `ptr`.
    fn getHeader(ptr: [*]u8) *Header {
        // Le header est juste avant les données
        const data_addr = @intFromPtr(ptr);

        // Calculer l'alignement du header
        const header_align_value: usize = @as(usize, 1) << @intFromEnum(header_alignment);

        // Le header se termine où les données commencent
        const header_end = data_addr;
        const header_start = header_end - @sizeOf(Header);

        // Trouver le début du header aligné
        const header_addr = std.mem.alignBackward(usize, header_start, header_align_value);

        return @ptrFromInt(header_addr);
    }

    /// Marque un bloc de mémoire précédemment alloué comme étant libre.
    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = ctx;
        _ = alignment;
        _ = return_address;

        // Récupérer le header associé à cette allocation
        const header = getHeader(buf.ptr);

        // Marquer comme libre
        header.free = true;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "allocations simples" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u8);
    const c = try allocator.create(u8);
    const d = try allocator.create(u8);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 1 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(c);

    const e = try allocator.create(u8);
    try expectEqual(c, e);

    const f = try allocator.create(u8);
    try expect(@intFromPtr(d) + 1 <= @intFromPtr(f));
}

test "allocations à plusieurs octets" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u64);
    const c = try allocator.create(u8);
    const d = try allocator.create(u16);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 8 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(a);
    allocator.destroy(b);
    allocator.destroy(c);
    allocator.destroy(d);

    const e = try allocator.create(u24);
    try expectEqual(@intFromPtr(b), @intFromPtr(e));

    const f = try allocator.create(u16);
    try expectEqual(@intFromPtr(d), @intFromPtr(f));

    const g = try allocator.create(u16);
    try expect(@intFromPtr(d) + 2 <= @intFromPtr(g));
}

test "allocation de tableaux" {
    var buffer: [128]u8 = undefined;
    var recycle = AllocateurRecycle.init(&buffer);
    const allocator = recycle.allocator();

    const a = try allocator.alloc(u8, 1);
    const b = try allocator.alloc(u32, 10);
    const c = try allocator.create(u64);

    try expect(@intFromPtr(&a[0]) + 1 <= @intFromPtr(&b[0]));
    try expectEqual(10, b.len);
    try expect(@intFromPtr(&b[9]) + 4 <= @intFromPtr(c));

    allocator.free(b);

    const d = try allocator.alloc(u64, 4);
    try expectEqual(@intFromPtr(b.ptr), @intFromPtr(d.ptr));
}
