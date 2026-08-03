const std = @import("std");

pub const TokenType = enum {
    keyword, // identifier matching a DSL keyword (validated by parser)
    string,  // "..." literal; text excludes the quotes
    lbrace,
    rbrace,
    semicolon,
    eqeq,
    eof,
    @"error",
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    line: u32,
    col: u32,
};

pub const LexError = error{ UnterminatedString, InvalidCharacter };

/// Error positions (err_line/err_col): invalid characters point at the
/// offending character; unterminated strings point at the string start.
pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    err_line: u32 = 1,
    err_col: u32 = 1,

    fn col(self: *const Lexer) u32 {
        return @intCast(self.pos - self.line_start + 1);
    }

    fn markErr(self: *Lexer) void {
        self.err_line = self.line;
        self.err_col = self.col();
    }

    pub fn next(self: *Lexer) LexError!Token {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                },
                '{' => {
                    const start_col = self.col();
                    self.pos += 1;
                    return .{ .type = .lbrace, .text = "{", .line = self.line, .col = start_col };
                },
                '}' => {
                    const start_col = self.col();
                    self.pos += 1;
                    return .{ .type = .rbrace, .text = "}", .line = self.line, .col = start_col };
                },
                ';' => {
                    const start_col = self.col();
                    self.pos += 1;
                    return .{ .type = .semicolon, .text = ";", .line = self.line, .col = start_col };
                },
                '=' => {
                    if (self.pos + 1 >= self.src.len or self.src[self.pos + 1] != '=') {
                        self.markErr();
                        return error.InvalidCharacter;
                    }
                    const t = Token{ .type = .eqeq, .text = "==", .line = self.line, .col = self.col() };
                    self.pos += 2;
                    return t;
                },
                '"' => return self.string(),
                else => {
                    if (std.ascii.isAlphanumeric(c) or c == '_') return self.identifier();
                    self.markErr();
                    return error.InvalidCharacter;
                },
            }
        }
        return .{ .type = .eof, .text = "", .line = self.line, .col = self.col() };
    }

    fn identifier(self: *Lexer) LexError!Token {
        const start = self.pos;
        const l = self.line;
        const c = self.col();
        while (self.pos < self.src.len and
            (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_'))
        {
            self.pos += 1;
        }
        return .{ .type = .keyword, .text = self.src[start..self.pos], .line = l, .col = c };
    }

    fn string(self: *Lexer) LexError!Token {
        const l = self.line;
        const c = self.col();
        self.err_line = l;
        self.err_col = c;
        self.pos += 1; // opening quote
        const start = self.pos;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '"' => {
                    const text = self.src[start..self.pos];
                    self.pos += 1;
                    return .{ .type = .string, .text = text, .line = l, .col = c };
                },
                '\\' => {
                    if (self.pos + 1 >= self.src.len or self.src[self.pos + 1] == '\n') return error.UnterminatedString;
                    self.pos += 2;
                },
                '\n' => return error.UnterminatedString,
                else => self.pos += 1,
            }
        }
        return error.UnterminatedString; // err_line/err_col already set at string start
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "tokenizes an on-block" {
    var lx = Lexer{ .src = "on click \"#btn\" { set_text \"hi\" on \"#out\"; }" };
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.string, (try lx.next()).type);
    try expectEqual(.lbrace, (try lx.next()).type);
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.string, (try lx.next()).type);
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.string, (try lx.next()).type);
    try expectEqual(.semicolon, (try lx.next()).type);
    try expectEqual(.rbrace, (try lx.next()).type);
    try expectEqual(.eof, (try lx.next()).type);
}

test "eqeq token" {
    var lx = Lexer{ .src = "if v == \"x\"" };
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.keyword, (try lx.next()).type);
    try expectEqual(.eqeq, (try lx.next()).type);
}

test "line and column tracking" {
    var lx = Lexer{ .src = "on\nclick \"#b\"" };
    const t1 = try lx.next();
    try expectEqual(@as(u32, 1), t1.line);
    const t2 = try lx.next();
    try expectEqual(@as(u32, 2), t2.line);
    try expectEqual(@as(u32, 1), t2.col);
    const t3 = try lx.next();
    try expectEqual(@as(u32, 7), t3.col); // "#b" starts at column 7 of line 2
}

test "unterminated string records error position" {
    var lx = Lexer{ .src = "on \"oops" };
    _ = try lx.next();
    try expectError(error.UnterminatedString, lx.next());
    try expectEqual(@as(u32, 1), lx.err_line);
    try expectEqual(@as(u32, 4), lx.err_col);
}

test "invalid character" {
    var lx = Lexer{ .src = "on @" };
    _ = try lx.next();
    try expectError(error.InvalidCharacter, lx.next());
}

test "newline inside string is unterminated" {
    var lx = Lexer{ .src = "on \"a\nb\"" };
    _ = try lx.next();
    try expectError(error.UnterminatedString, lx.next());
    try expectEqual(@as(u32, 1), lx.err_line);
    try expectEqual(@as(u32, 4), lx.err_col);
}

test "escaped newline inside string is unterminated" {
    var lx = Lexer{ .src = "on \"a\\\nb\"" };
    _ = try lx.next();
    try expectError(error.UnterminatedString, lx.next());
    try expectEqual(@as(u32, 1), lx.err_line);
    try expectEqual(@as(u32, 4), lx.err_col);
}

test "escaped quote does not end the string" {
    var lx = Lexer{ .src = "\"a\\\"b\"" };
    const t = try lx.next();
    try expectEqualStrings("a\\\"b", t.text);
    try expectEqual(.eof, (try lx.next()).type);
}

test "CRLF line counting" {
    var lx = Lexer{ .src = "on\r\nclick" };
    _ = try lx.next();
    const t = try lx.next();
    try expectEqual(@as(u32, 2), t.line);
    try expectEqual(@as(u32, 1), t.col);
}

test "lone equals error position" {
    var lx = Lexer{ .src = "on =" };
    _ = try lx.next();
    try expectError(error.InvalidCharacter, lx.next());
    try expectEqual(@as(u32, 1), lx.err_line);
    try expectEqual(@as(u32, 4), lx.err_col);
}
