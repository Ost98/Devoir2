const std = @import("std");

const Header = struct {
    len: usize,
    free: bool,
};

const header_alignment = std.mem.Alignment.of(Header);

const AllocateurEtiquette = struct {
    buffer: []u8,
    next: usize,

    /// Crée un allocateur à étiquetage gérant la zone de mémoire délimitée
    /// par la tranche `buffer`.
    fn init(buffer: []u8) AllocateurEtiquette {
        return .{
            .buffer = buffer,
            .next = 0,
        };
    }

    /// Retourne l’interface générique d’allocateur correspondant à
    /// cet allocateur à étiquetage.
    fn allocator(self: *AllocateurEtiquette) std.mem.Allocator {
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

    /// Tente d’allouer un bloc de mémoire de `len` octets dont l’adresse
    /// est alignée suivant `alignment`. Retourne un pointeur vers le début
    /// du bloc alloué, ou `null` pour indiquer un échec d’allocation.
    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;

        const self: *AllocateurEtiquette = @ptrCast(@alignCast(ctx));

        // 1. Aligner pour le Header
        const header_align_value: usize = @as(usize, 1) << @intFromEnum(header_alignment);
        const header_start = std.mem.alignForward(usize, self.next, header_align_value);

        // 2. Calculer la position après le header
        const data_start_unaligned = header_start + @sizeOf(Header);

        // 3. Aligner pour les données
        const align_value: usize = @as(usize, 1) << @intFromEnum(alignment);
        const data_start = std.mem.alignForward(usize, data_start_unaligned, align_value);

        // 4. Calculer la fin de l'allocation
        const data_end = data_start + len;

        // 5. Vérifier si on dépasse le buffer
        if (data_end > self.buffer.len) {
            return null;
        }

        // 6. Créer et initialiser le header
        const header_ptr: *Header = @ptrCast(@alignCast(&self.buffer[header_start]));
        header_ptr.* = Header{
            .len = len,
            .free = false,
        };

        // 7. Mettre à jour next
        self.next = data_end;

        // 8. Retourner le pointeur vers les données
        return self.buffer[data_start..data_end].ptr;
    }

    /// Récupère l'en-tête associé à l'allocation débutant à l'adresse `ptr`.
    fn getHeader(ptr: [*]u8) *Header {
        // Le header est juste avant les données
        // On recule de la taille d'un Header, mais en tenant compte de l'alignement
        const data_addr = @intFromPtr(ptr);

        // Calculer l'adresse du header (juste avant les données, aligné)
        const header_align_value: usize = @as(usize, 1) << @intFromEnum(header_alignment);

        // Le header se termine où les données commencent
        // Donc le header commence à (data_addr - taille_avec_padding)
        // On cherche l'adresse alignée la plus proche avant data_addr
        const header_end = data_addr;
        const header_start = header_end - @sizeOf(Header);

        // Trouver le début du header aligné (on recule jusqu'à l'alignement)
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
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u8);
    const c = try allocator.create(u8);
    const d = try allocator.create(u8);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 1 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(d)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(d)).len);

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(c);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);
}

test "allocations à plusieurs octets" {
    var buffer: [128]u8 = undefined;
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.create(u8);
    const b = try allocator.create(u64);
    const c = try allocator.create(u8);
    const d = try allocator.create(u16);

    try expect(@intFromPtr(a) + 1 <= @intFromPtr(b));
    try expect(@intFromPtr(b) + 8 <= @intFromPtr(c));
    try expect(@intFromPtr(c) + 1 <= @intFromPtr(d));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(d)).free);
    try expectEqual(2, AllocateurEtiquette.getHeader(@ptrCast(d)).len);

    a.* = 4;
    b.* = 5;
    c.* = 6;
    d.* = 7;

    try expectEqual(4, a.*);
    try expectEqual(5, b.*);
    try expectEqual(6, c.*);
    try expectEqual(7, d.*);

    allocator.destroy(b);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(b)).len);
}

test "allocation de tableaux" {
    var buffer: [128]u8 = undefined;
    var etiquette = AllocateurEtiquette.init(&buffer);
    const allocator = etiquette.allocator();

    const a = try allocator.alloc(u8, 1);
    const b = try allocator.alloc(u32, 10);
    const c = try allocator.create(u64);

    try expect(@intFromPtr(&a[0]) + 1 <= @intFromPtr(&b[0]));
    try expectEqual(10, b.len);
    try expect(@intFromPtr(&b[9]) + 4 <= @intFromPtr(c));

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(a)).free);
    try expectEqual(1, AllocateurEtiquette.getHeader(@ptrCast(a)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(40, AllocateurEtiquette.getHeader(@ptrCast(b)).len);

    try expectEqual(false, AllocateurEtiquette.getHeader(@ptrCast(c)).free);
    try expectEqual(8, AllocateurEtiquette.getHeader(@ptrCast(c)).len);

    allocator.free(b);

    try expectEqual(true, AllocateurEtiquette.getHeader(@ptrCast(b)).free);
    try expectEqual(40, AllocateurEtiquette.getHeader(@ptrCast(b)).len);
}
