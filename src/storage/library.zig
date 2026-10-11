const std = @import("std");

pub const capacity = 255;
pub const max_path_bytes = 128;
pub const visible_rows: u8 = 6;

pub const Book = struct {
    path: [max_path_bytes:0]u8 = [_:0]u8{0} ** max_path_bytes,
    len: u8 = 0,

    pub fn slice(self: *const Book) []const u8 {
        return self.path[0..self.len];
    }

    pub fn zSlice(self: *const Book) [:0]const u8 {
        return self.path[0..self.len :0];
    }
};

pub fn displayTitle(path: []const u8) []const u8 {
    return if (isEpub(path)) path[0 .. path.len - 5] else path;
}

pub const Library = struct {
    books: [capacity]Book = undefined,
    sort_scratch: Book = undefined,
    len: u8 = 0,
    selected: u8 = 0,
    first_visible: u8 = 0,
    omitted_capacity: u32 = 0,
    omitted_names: u32 = 0,
    listing_failed: bool = false,

    pub fn add(self: *Library, path: []const u8) void {
        if (path.len == 0 or !isEpub(path)) return;
        if (path.len >= max_path_bytes) {
            self.omitted_names +|= 1;
            return;
        }
        var index: usize = self.len;
        if (self.len == capacity) {
            self.omitted_capacity +|= 1;
            // Keep the alphabetically first 255 regardless of enumeration order.
            index = 0;
            for (self.books[0..self.len], 0..) |*book, candidate| {
                if (pathLessThan(self.books[index].slice(), book.slice())) index = candidate;
            }
            if (!pathLessThan(path, self.books[index].slice())) return;
        }
        const book = &self.books[index];
        @memcpy(book.path[0..path.len], path);
        book.path[path.len] = 0;
        book.len = @intCast(path.len);
        if (self.len < capacity) self.len += 1;
    }

    pub fn reset(self: *Library) void {
        self.len = 0;
        self.selected = 0;
        self.first_visible = 0;
        self.omitted_capacity = 0;
        self.omitted_names = 0;
        self.listing_failed = false;
    }

    pub fn sort(self: *Library) void {
        // std.mem.sort reserves tens of KiB for Book elements. With at most 255 books,
        // insertion sort keeps scratch on the heap and avoids recursion.
        for (1..@max(@as(usize, 1), self.len)) |index| {
            @memcpy(std.mem.asBytes(&self.sort_scratch), std.mem.asBytes(&self.books[index]));
            var destination = index;
            while (destination != 0 and pathLessThan(self.sort_scratch.slice(), self.books[destination - 1].slice())) : (destination -= 1) {
                @memcpy(std.mem.asBytes(&self.books[destination]), std.mem.asBytes(&self.books[destination - 1]));
            }
            @memcpy(std.mem.asBytes(&self.books[destination]), std.mem.asBytes(&self.sort_scratch));
        }
    }

    pub fn find(self: *const Library, path: []const u8) ?u8 {
        for (self.books[0..self.len], 0..) |*book, index| if (std.mem.eql(u8, path, book.slice())) return @intCast(index);
        return null;
    }

    pub fn select(self: *Library, index: u8) void {
        self.selected = if (self.len == 0) 0 else @min(index, self.len - 1);
        self.ensureSelectedVisible();
    }

    pub fn move(self: *Library, direction: i16) void {
        if (self.len == 0 or direction == 0) return;
        const target = @mod(@as(i32, self.selected) + @as(i32, direction), @as(i32, self.len));
        self.selected = @intCast(target);
        self.ensureSelectedVisible();
    }

    pub fn selectedBook(self: *const Library) ?*const Book {
        if (self.len == 0) return null;
        return &self.books[self.selected];
    }

    fn ensureSelectedVisible(self: *Library) void {
        if (self.selected < self.first_visible) {
            self.first_visible = self.selected;
            return;
        }
        const last_visible = self.first_visible +| visible_rows - 1;
        if (self.selected > last_visible) self.first_visible = self.selected - visible_rows + 1;
    }
};

fn pathLessThan(a: []const u8, b: []const u8) bool {
    const order = std.ascii.orderIgnoreCase(a, b);
    return if (order == .eq) std.mem.order(u8, a, b) == .lt else order == .lt;
}

fn isEpub(path: []const u8) bool {
    if (path.len < 5) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".epub");
}

test "library retains bounded EPUB choices and cycles selection" {
    var library = Library{};
    library.add("notes.txt");
    library.add("books/one.epub");
    library.add("books/TWO.EPUB");
    try std.testing.expectEqual(@as(u8, 2), library.len);
    try std.testing.expectEqualStrings("books/one.epub", library.selectedBook().?.slice());
    library.move(1);
    try std.testing.expectEqualStrings("books/TWO.EPUB", library.selectedBook().?.slice());
    library.move(1);
    try std.testing.expectEqualStrings("books/one.epub", library.selectedBook().?.slice());
}

test "library scrolls only when selection crosses a viewport edge" {
    var library = Library{};
    for (0..8) |index| {
        var path: [16]u8 = undefined;
        library.add(try std.fmt.bufPrint(&path, "book-{d}.epub", .{index}));
    }

    for (0..6) |_| library.move(1);
    try std.testing.expectEqual(@as(u8, 6), library.selected);
    try std.testing.expectEqual(@as(u8, 1), library.first_visible);

    library.move(-1);
    try std.testing.expectEqual(@as(u8, 5), library.selected);
    try std.testing.expectEqual(@as(u8, 1), library.first_visible);

    for (0..5) |_| library.move(-1);
    try std.testing.expectEqual(@as(u8, 0), library.selected);
    try std.testing.expectEqual(@as(u8, 0), library.first_visible);
}

test "display title omits an EPUB extension case insensitively" {
    try std.testing.expectEqualStrings("books/one", displayTitle("books/one.epub"));
    try std.testing.expectEqualStrings("books/TWO", displayTitle("books/TWO.EPUB"));
    try std.testing.expectEqualStrings("notes.txt", displayTitle("notes.txt"));
}

test "255-book catalog preserves the final entry and wraps navigation without overflow" {
    const library = try std.testing.allocator.create(Library);
    defer std.testing.allocator.destroy(library);
    library.reset();
    for (0..capacity) |index| {
        var path: [24]u8 = undefined;
        library.add(try std.fmt.bufPrint(&path, "book-{d:0>3}.epub", .{index}));
    }
    try std.testing.expectEqual(@as(u8, 255), library.len);
    library.move(-1);
    try std.testing.expectEqual(@as(u8, 254), library.selected);
    try std.testing.expectEqual(@as(u8, 249), library.first_visible);
    try std.testing.expectEqualStrings("book-254.epub", library.selectedBook().?.slice());
    library.move(1);
    try std.testing.expectEqual(@as(u8, 0), library.selected);
    try std.testing.expectEqual(@as(u8, 0), library.first_visible);
    library.select(255);
    try std.testing.expectEqual(@as(u8, 254), library.selected);
}

test "overflow keeps the same sorted catalog in either enumeration order and counts rejected names" {
    const forward = try std.testing.allocator.create(Library);
    defer std.testing.allocator.destroy(forward);
    const reverse = try std.testing.allocator.create(Library);
    defer std.testing.allocator.destroy(reverse);
    forward.reset();
    reverse.reset();
    for (0..capacity + 10) |index| {
        var path: [24]u8 = undefined;
        forward.add(try std.fmt.bufPrint(&path, "book-{d:0>3}.epub", .{index}));
        reverse.add(try std.fmt.bufPrint(&path, "book-{d:0>3}.epub", .{capacity + 9 - index}));
    }
    forward.sort();
    reverse.sort();
    try std.testing.expectEqual(@as(u32, 10), reverse.omitted_capacity);
    for (0..capacity) |index| try std.testing.expectEqualStrings(forward.books[index].slice(), reverse.books[index].slice());
    var longest = [_]u8{'a'} ** 128;
    @memcpy(longest[123..], ".epub");
    reverse.add(&longest);
    try std.testing.expectEqual(@as(u32, 1), reverse.omitted_names);
    reverse.reset();
    var accepted = [_]u8{'a'} ** 127;
    @memcpy(accepted[122..], ".epub");
    reverse.add(&accepted);
    try std.testing.expectEqual(@as(u8, 1), reverse.len);
    try std.testing.expectEqualStrings(&accepted, reverse.selectedBook().?.slice());
    try std.testing.expectEqual(@as(u8, 0), reverse.selectedBook().?.path[127]);
}
