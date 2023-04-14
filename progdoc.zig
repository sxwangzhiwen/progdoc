const std = @import("std");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const print = std.debug.print;
const assert = std.debug.assert;
const process = std.process;
const html = @import("./html.zig");

//编写说明：
//1.按规范编写方式，不应该把所有的写到1个源代码文件中，应该根据功能分为若干个源代码文件。
//但考虑到这个程序功能单一，规模又小，就不费那个劲了。
//2.编程最难的是起名，最烦的是中后期debug。
//做为一个英文非母语的中国程序员，起一个对应中文名字的英文名太难了。
//所以把函数名和主要变量、类型名均起成中文名字，写起程序来顺畅多了，而且少写太多的注释。
//这个程序基本定型了，也不指望有多少人（包括国外程序员）有贡献，所以不用考虑外国人看不懂中文名字了。

//总体流程：
//逐行解析出 @"当前行类别"，并且和@"上一行状态"，一起推导出@"当前行状态"；
//根据@"当前行状态"，执行对应的函数处理当前行；
//对于表格而言，还须结合@"上一行表格状态"，执行对应函数处理当前表格行；
//对于表格的每个单元格，还需要判定@"当前表格单元格类别"，来填充单元格内容。

//一些大写字符含义：T 表示类型； S表示开始，C表示继续，E表示结束。
//绝大部分函数都有对应的测试用例，每写一个函数，就顺手定了测试，这是zig语言的优势所在，很方便。

const @"T当前行状态" = enum {
    @"格式正文行",
    @"标题行",
    @"多行代码行S",
    @"多行代码行E",
    @"多行代码行C",
    @"列表S",
    @"列表C",
    @"表格S",
    @"表格C",
    @"内嵌html多行S",
    @"内嵌html多行C",
    @"内嵌html多行E",
};

//单行列表行、多行列表行S、多行列表行E前面可以有空格、制表符这两类空白字符；其余类别必须是在行首。
//单行列表行、多行列表行S、多行列表行E可以在表格单元格内，其余类别不可以。
//为了区分，多行代码SE、多行列表行SE后面不能有任何字符，只能是换行符或文件尾。
//多行表格行SE、内嵌html多行S、内嵌html多行E后面到行尾中间可以有字符，这些字符无任何用处。
const @"T当前行类别" = enum {
    @"格式正文行",
    @"标题行", // 1.1. AAA
    @"多行代码S", // ``` AAA.zig
    @"多行代码SE", // ```
    @"单行列表行", // #- AAA
    @"多行列表行S", // #-- AAA
    @"多行列表行E", // #--
    @"多行表格行SE", // #|-
    @"单行表格行", // #| AAA
    @"内嵌html多行S", // #<<
    @"内嵌html多行E", // #>>
};

const @"T上一行状态" = enum {
    @"无后续影响",
    @"多行代码行C",
    @"列表C",
    @"表格C",
    @"内嵌html多行C",
};

const @"T当前表格单元格类别" = enum {
    @"格式正文行",
    @"单行列表行",
    @"多行列表行S",
    @"多行列表行E",
};

//多行表格行是指多行表示1个表格行。
const @"T上一行表格状态" = enum {
    @"单行表格行C",
    @"多行表格开始行", // 整个表格开始行，后面是多行表格行
    @"多行表格行开始行", // 在表格中的多行表格开始行
    @"多行表格行C",
};

const progdoc_err = error{
    @"短代码无结束`字符",
    @"内链无结束]]字符串",
    @"内链中含有[[字符串",
    @"外链说明无#](结束字符串",
    @"外链说明中含有#[或#]字符串",
    @"外链链接中含有(字符",
    @"外链链接无)结束字符",
    @"图片说明无#](结束字符串",
    @"图片说明中含有#[或#]字符串",
    @"图片链接中含有(字符",
    @"图片链接无)结束字符",
    @"当前行是多行代码行S但上一行状态是多行代码行C",
    @"多行代码没有结束行",
    @"push时列表栈满",
    @"pop时列表栈空",
    @"get时列表栈空",
    @"set时列表栈空",
    @"多行列表行结束行没有对应的开始行",
    @"多行列表行没有对应的结束行",
    @"多行表格行缓冲溢出错误",
    @"与上一行表格列数不相等",
    @"多行表格行是空行",
    @"内嵌html结束行没有对应的开始行",
    @"当前行是内嵌html多行S但上一行状态是内嵌html多行C",
    @"内嵌html多行没有结束行",
};

pub const @"Tprogdoc格式转换状态机" = struct {
    in: []const u8, // 读取缓冲区
    out: std.ArrayList(u8), // 多行表格行输出时，需要暂时变到多行输出缓冲
    @"行号": usize = 1, // 主要用于出错信息显示
    @"当前行开始索引": usize = 0,
    @"当前行类别": @"T当前行类别" = undefined,
    @"上一行状态": @"T上一行状态" = .@"无后续影响",
    index: usize = 0, // 当前行解析的当前字符索引
    @"标题级数": u8 = 0,
    @"目录": std.ArrayList(u8), // 目录暂时缓冲区，文本处理完后插入到输出流的@"插入目录位置"
    @"插入目录位置": usize = 0,
    @"当前行状态": @"T当前行状态" = .@"格式正文行",
    @"is输入尾部": bool = false, // 当 true 时表示读到文件尾部，需要结束处理。
    @"文档列表栈": @"T列表栈" = .{}, // 为了处理多级列表，引入多行列表行，需要用栈来实现。
    @"表格总列数": usize = 0, // 处理表格时，单元格的总个数。
    @"表格当前列序号": usize = 0,
    @"表格单元格列表栈": std.ArrayList(@"T列表栈"), // 处理多行表格行中的列表，以实现在表格单元格中写列表。
    @"当前表格单元格类别": @"T当前表格单元格类别" = undefined,
    @"上一行表格状态": @"T上一行表格状态" = undefined,
    @"多行表格行缓冲": MultiRowTableBuffer, // 处理多行表格行时的暂时缓冲输出。
    @"多行表格temp": std.ArrayList(u8), // 处理多行表格行时的配套变量。
    @"内链外链图片temp": std.ArrayList(u8), //处理相应格式时的配套变量。
    //
    const Self = @This();

    //输入的是待解析的文本。后续函数参数使用的均是指针，是为了在函数中能改变状态机的属性值。
    //初始化状态机
    pub fn createStatusMachine(al: std.mem.Allocator, inbuf: []const u8) !@"Tprogdoc格式转换状态机" {
        var list = try std.ArrayList(u8).initCapacity(al, 80);
        var list1 = try std.ArrayList(u8).initCapacity(al, 80);
        try list1.appendSlice("<ul>\r\n");
        var list2 = try std.ArrayList(@"T列表栈").initCapacity(al, 16);
        var list3 = try std.ArrayList(u8).initCapacity(al, 80);
        var list4 = try std.ArrayList(u8).initCapacity(al, 80);
        var b = try MultiRowTableBuffer.createMultiRowTableBuf(al);
        return .{
            .in = inbuf,
            .out = list,
            .@"目录" = list1,
            .@"表格单元格列表栈" = list2,
            .@"多行表格行缓冲" = b,
            .@"多行表格temp" = list3,
            .@"内链外链图片temp" = list4,
        };
    }

    pub fn @"Fn判断当前行类别"(self: *Self) void {
        var i = self.@"当前行开始索引";
        var j: i8 = -1;
        switch (self.in[i]) {
            '`' => {
                j = @"Fnis包含字符串"(self.in, &i, .{
                    "```\r",
                    "```\n",
                    "```",
                });
                switch (j) {
                    0, 1 => {
                        self.@"当前行类别" = .@"多行代码SE";
                        i -= 1;
                    },
                    2 => {
                        if (i == self.in.len) {
                            self.@"当前行类别" = .@"多行代码SE";
                        } else {
                            self.@"当前行类别" = .@"多行代码S";
                        }
                    },
                    else => {
                        self.@"当前行类别" = .@"格式正文行";
                    },
                }
            },
            '0'...'9' => {
                var @"is标题": bool = false;
                var @"句点个数": u8 = 0;
                while (i < self.in.len) : (i += 1) {
                    if (self.in[i] != '.' and (self.in[i] < '0' or self.in[i] > '9')) {
                        break;
                    }
                    if (self.in[i] == '.') {
                        @"句点个数" += 1;
                        if (i == self.in.len - 1) {
                            @"is标题" = true;
                            break;
                        }
                        if (self.in[i + 1] < '0' or self.in[i + 1] > '9') {
                            @"is标题" = true;
                            break;
                        }
                    }
                }
                if (@"is标题") {
                    i += 1;
                    self.@"当前行类别" = .@"标题行";
                    self.@"标题级数" = @"句点个数";
                } else {
                    i = self.@"当前行开始索引";
                    self.@"当前行类别" = .@"格式正文行";
                }
            },
            ' ', '\t', '#' => {
                j = @"Fnis包含字符串"(self.in, &i, .{ "#|-", "#|", "#<<", "#>>" });
                switch (j) {
                    0 => {
                        self.@"当前行类别" = .@"多行表格行SE";
                    },
                    1 => {
                        self.@"当前行类别" = .@"单行表格行";
                    },
                    2 => {
                        self.@"当前行类别" = .@"内嵌html多行S";
                    },
                    3 => {
                        self.@"当前行类别" = .@"内嵌html多行E";
                    },
                    else => {
                        while (i < self.in.len) : (i += 1) {
                            if (self.in[i] != ' ' and self.in[i] != '\t') {
                                break;
                            }
                        }
                        j = @"Fnis包含字符串"(self.in, &i, .{ "#--\r", "#--\n", "#--", "#-" });
                        switch (j) {
                            0, 1 => {
                                self.@"当前行类别" = .@"多行列表行E";
                                i -= 1;
                            },
                            2 => {
                                if (i == self.in.len) {
                                    self.@"当前行类别" = .@"多行列表行E";
                                } else {
                                    self.@"当前行类别" = .@"多行列表行S";
                                }
                            },
                            3 => {
                                self.@"当前行类别" = .@"单行列表行";
                            },
                            else => {
                                i = self.@"当前行开始索引";
                                self.@"当前行类别" = .@"格式正文行";
                            },
                        }
                    },
                }
            },
            else => {
                self.@"当前行类别" = .@"格式正文行";
            },
        }
        self.index = i;
    }

    pub fn @"Fn清空状态机"(s: *Self) void {
        s.in = undefined;
        s.out.deinit();
        s.@"目录".deinit();
        s.@"表格单元格列表栈".deinit();
        s.@"多行表格temp".deinit();
        s.@"内链外链图片temp".deinit();
        s.@"多行表格行缓冲".delectMulitTableBuffer();
        s.out = undefined;
    }
    //     仅对< > 进行实体替换，其它字符原样输出。用于多行代码行。
    pub fn @"Fn无格式正文字符"(self: *@"Tprogdoc格式转换状态机") !void {
        switch (self.in[self.index]) {
            '<' => {
                try self.out.appendSlice("&lt;");
            },
            '>' => {
                try self.out.appendSlice("&gt;");
            },
            else => |v| {
                try self.out.append(v);
            },
        }
        self.index += 1;
    }

    // < > 实体替换，#` 替换为 ` ，用于普通正文字符输出。
    pub fn @"Fn普通正文字符"(self: *@"Tprogdoc格式转换状态机") !void {
        switch (self.in[self.index]) {
            '<' => {
                try self.out.appendSlice("&lt;");
            },
            '>' => {
                try self.out.appendSlice("&gt;");
            },
            '#' => {
                const j = @"Fnis包含字符串"(self.in, &self.index, .{"#`"});
                if (j == 0) {
                    try self.out.append('`');
                    self.index -= 1;
                } else {
                    try self.out.append('#');
                }
            },
            else => |v| {
                try self.out.append(v);
            },
        }
        self.index += 1;
    }

    // BB`` AAA\r\n
    // <code>AAA</code>
    //从``后到行尾的所有字符原样输出，仅 < > 字符实体替换和 #` 替换为 `
    //在表格中或正文中间慎重使用，容易出错。
    pub fn @"Fn行代码"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<code>");
        while (self.index < self.in.len) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                try self.out.appendSlice("</code>");
                return;
            }
            try self.@"Fn普通正文字符"();
        }
        try self.out.appendSlice("</code>");
    }

    // `AAA`
    // <code>AAA</code>
    // 主要用于正常输出 [[ 等格式控制用的字符（类似于 \ 逃逸字符，或者用于程序短代码。
    pub fn @"Fn短代码"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<code>");
        while (self.index < self.in.len) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                return progdoc_err.@"短代码无结束`字符";
            }
            if (self.in[self.index] == '`') {
                try self.out.appendSlice("</code>");
                self.index += 1;
                return;
            }
            try self.@"Fn普通正文字符"();
        }
        return progdoc_err.@"短代码无结束`字符";
    }

    // AA`BB`CC
    // AA<code>BB</code>
    // 该函数主要用于内链、外链说明等处。
    pub fn @"Fn普通正文字符和短代码"(self: *@"Tprogdoc格式转换状态机") !void {
        if (self.in[self.index] == '`') {
            const j = @"Fnis包含字符串"(self.in, &self.index, .{ "`\n", "`\r", "``" });
            if (j > 0 or self.index == self.in.len - 1) {
                return progdoc_err.@"短代码无结束`字符";
            }
            self.index += 1;
            try self.@"Fn短代码"();
        } else {
            try self.@"Fn普通正文字符"();
        }
    }

    /// [[AAA]]
    /// <a href="#NAAA">AAA</a>
    /// 为了和标题锚点对应上，内链在链接处加 N 字符。因为数字开头的内链html不能正确处理。
    /// 没有锚点设置功能，建议写文档时分章节尽量短，内链只对应标题。
    ///内链中不能有 [[ ]] 字符串，分影响正确解析。
    pub fn @"Fn内链"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<a href=\"#");
        try self.out.append('N');
        const istart = self.out.items.len;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '\n', '\r', '[', ']' => {
                    var j = @"Fnis包含字符串"(self.in, &self.index, .{ "\n", "\r", "[[", "]]" });
                    switch (j) {
                        0, 1 => {
                            return progdoc_err.@"内链无结束]]字符串";
                        },
                        2 => {
                            return progdoc_err.@"内链中含有[[字符串";
                        },
                        3 => {
                            const iend = self.out.items.len;
                            self.@"内链外链图片temp".items.len = 0;
                            try self.@"内链外链图片temp".appendSlice(self.out.items[istart..iend]);
                            try self.out.appendSlice("\">");
                            try self.out.appendSlice(self.@"内链外链图片temp".items);
                            try self.out.appendSlice("</a>");
                            return;
                        },
                        else => {
                            try self.@"Fn普通正文字符和短代码"();
                        },
                    }
                },
                else => {
                    try self.@"Fn普通正文字符和短代码"();
                },
            }
        }
        return progdoc_err.@"内链无结束]]字符串";
    }

    /// #[AAA#](BBB)
    /// <a href="BBB">AAA</a>
    /// 外链说明中，不能有 #[ #] 字符串，外链链接中，不能有 ( ) 字符，否则影响正常解析。
    /// 外链链接中，不建议有< > #` 字符，因为会实体替换。
    pub fn @"Fn外链"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<a href=\"");
        const ipost = self.out.items.len;
        var isok: bool = false;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '\n', '\r' => {
                    return progdoc_err.@"外链说明无#](结束字符串";
                },
                '#' => {
                    var j = @"Fnis包含字符串"(self.in, &self.index, .{ "#](", "#[", "#]" });
                    switch (j) {
                        0 => {
                            isok = true;
                            break;
                        },
                        1, 2 => {
                            return progdoc_err.@"外链说明中含有#[或#]字符串";
                        },
                        else => {
                            try self.@"Fn普通正文字符和短代码"();
                        },
                    }
                },
                else => {
                    try self.@"Fn普通正文字符和短代码"();
                },
            }
        }
        if (!isok) {
            return progdoc_err.@"外链说明无#](结束字符串";
        }
        isok = false;
        const istart = self.out.items.len;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '(' => {
                    return progdoc_err.@"外链链接中含有(字符";
                },
                '\n', '\r' => {
                    return progdoc_err.@"外链链接无)结束字符";
                },
                ')' => {
                    isok = true;
                    self.index += 1;
                    break;
                },
                else => {
                    try @"Fn普通正文字符"(self);
                },
            }
        }
        if (!isok) {
            return progdoc_err.@"外链链接无)结束字符";
        }
        try self.out.appendSlice("\">");
        const iend = self.out.items.len;
        self.@"内链外链图片temp".items.len = 0;
        try self.@"内链外链图片temp".appendSlice(self.out.items[istart..iend]);
        try self.out.insertSlice(ipost, self.@"内链外链图片temp".items);
        self.out.items.len = iend;
        try self.out.appendSlice("</a>");
    }

    /// !#[AAA#](BBB)
    /// <img src="BBB" alt="AAA" />
    /// 图片处理，和外链类似。
    pub fn @"Fn图片"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<img src=\"");
        const ipost = self.out.items.len;
        var isok: bool = false;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '\n', '\r' => {
                    return progdoc_err.@"图片说明无#](结束字符串";
                },
                '#' => {
                    var j = @"Fnis包含字符串"(self.in, &self.index, .{ "#](", "#[", "#]" });
                    switch (j) {
                        0 => {
                            isok = true;
                            break;
                        },
                        1, 2 => {
                            return progdoc_err.@"图片说明中含有#[或#]字符串";
                        },
                        else => {
                            try self.@"Fn普通正文字符和短代码"();
                        },
                    }
                },
                else => {
                    try self.@"Fn普通正文字符和短代码"();
                },
            }
        }
        if (!isok) {
            return progdoc_err.@"图片说明无#](结束字符串";
        }
        isok = false;
        const istart = self.out.items.len;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '(' => {
                    return progdoc_err.@"图片链接中含有(字符";
                },
                '\n', '\r' => {
                    return progdoc_err.@"图片链接无)结束字符";
                },
                ')' => {
                    isok = true;
                    self.index += 1;
                    break;
                },
                else => {
                    try self.@"Fn普通正文字符"();
                },
            }
        }
        if (!isok) {
            return progdoc_err.@"图片链接无)结束字符";
        }
        try self.out.appendSlice("\" alt=\"");
        const iend = self.out.items.len;
        self.@"内链外链图片temp".items.len = 0;
        try self.@"内链外链图片temp".appendSlice(self.out.items[istart..iend]);
        try self.out.insertSlice(ipost, self.@"内链外链图片temp".items);
        self.out.items.len = iend;
        try self.out.appendSlice("\" />");
    }

    /// 处理普通正文，可以包括：短代码、行代码、内链、外链、图片、其它字符。
    /// istable为假时，表示当前行非表格行，一直处理到行尾或输入尾；
    /// istable为真时，表示当前行是表格行，处理到 #| 表格分界符或行尾或输入尾。
    pub fn @"Fn格式正文C"(self: *@"Tprogdoc格式转换状态机", comptime istable: bool) !void {
        var i: i8 = -1;
        while (self.index < self.in.len) {
            switch (self.in[self.index]) {
                '`' => {
                    i = @"Fnis包含字符串"(self.in, &self.index, .{"``"});
                    if (i == 0) {
                        try self.@"Fn行代码"();
                    } else {
                        self.index += 1;
                        try self.@"Fn短代码"();
                    }
                },
                '[' => {
                    i = @"Fnis包含字符串"(self.in, &self.index, .{"[["});
                    if (i == 0) {
                        try self.@"Fn内链"();
                    } else {
                        try self.out.append('[');
                        self.index += 1;
                    }
                },
                '!' => {
                    i = @"Fnis包含字符串"(self.in, &self.index, .{"!#["});
                    if (i == 0) {
                        try self.@"Fn图片"();
                    } else {
                        try self.out.append('!');
                        self.index += 1;
                    }
                },
                '#' => {
                    i = @"Fnis包含字符串"(self.in, &self.index, .{ "#[", "#|" });
                    switch (i) {
                        0 => {
                            try self.@"Fn外链"();
                        },
                        1 => {
                            if (istable) {
                                self.index -= 2;
                                return;
                            } else {
                                try self.out.appendSlice("#|");
                            }
                        },
                        else => {
                            try self.@"Fn普通正文字符"();
                        },
                    }
                },
                '\n', '\r' => {
                    return;
                },
                else => {
                    try self.@"Fn普通正文字符"();
                },
            }
        }
    }

    /// 处理普通正文行
    pub fn @"Fn格式正文行"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<p>");
        try self.@"Fn格式正文C"(false);
        try self.out.appendSlice("</p>\r\n");
        self.@"上一行状态" = .@"无后续影响";
    }

    ///AAA.BBB
    ///<hN id="NAAA.BBB"><a href="#toc-AAA.BBB">AAA.BBB</a></hN>
    ///目录：
    ///<li><a id="toc-AAA.BBB" href="#NAAA.BBB">XXAAA.BBB</a></li>
    /// 其中N是标题级别，XX是N-1个&nbsp;  &nbsp;是空格的字符实体
    /// 处理标题行和目录。
    pub fn @"Fn标题行"(self: *@"Tprogdoc格式转换状态机") !void {
        var t = if (self.@"标题级数" > 6) 6 else self.@"标题级数";
        try self.out.writer().print("<h{} id=\"N", .{t});
        const istart = self.out.items.len;
        var iend = istart;
        self.index = self.@"当前行开始索引";
        while (self.index < self.in.len) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                iend = self.out.items.len;
                break;
            }
            try self.@"Fn普通正文字符和短代码"();
        }
        if (self.index == self.in.len) {
            iend = self.out.items.len;
        }
        try self.out.writer().print("\"><a href=\"#toc-{0s}\">{0s}</a></h{1}>\r\n", .{ self.out.items[istart..iend], t });
        try self.@"目录".writer().print("<li><a id=\"toc-{0s}\" href=\"#N{0s}\">", .{self.out.items[istart..iend]});
        t -= 1;
        while (t > 0) : (t -= 1) {
            try self.@"目录".appendSlice("&nbsp;&nbsp;");
        }
        try self.@"目录".writer().print("{s}</a></li>", .{self.out.items[istart..iend]});
        self.@"上一行状态" = .@"无后续影响";
    }

    //根据上一行状态和当前行类别，如果需要执行上一行状态结束函数，或者状态不对返回错误
    //正常则返回下一步处理的状态。

    //状态转移表
    //                无后续影响       内嵌html多行C    多行代码行C       表格C                列表C
    //格式正文行        格式正文行       内嵌html多行C    多行代码行C      表格E|格式正文行       如果是列表开始单行，则列表E|格式正文行；否则列表C
    //标题行            标题行          内嵌html多行C    多行代码行C      表格E|标题行          列表E|标题行
    //多行代码S         多行代码行S      内嵌html多行C    ERR            表格E|多行代码行S      列表E|多行S
    //多行代码SE        多行代码行S      内嵌html多行C    多行代码行E      表格E|多行代码行S      列表E|多行S
    //单行列表行        列表S           内嵌html多行C    多行代码行C      表格E|列表S           列表C
    //多行列表行S       列表S           内嵌html多行C    多行代码行C      表格E|列表S           列表C
    //多行列表行E       ERR             内嵌html多行C    多行代码行C     表格E|ERR             列表C
    //多行表格行SE      表格S           内嵌html多行C    多行代码行C      表格C                 列表E|表格S
    //单行表格行        表格S           内嵌html多行C    多行代码行C      表格C                 列表E|表格S
    //内嵌html多行S     内嵌html多行S   ERR             多行代码行C      表格E|内嵌html多行S    表格E|内嵌html多行S
    //内嵌html多行E     ERR            内嵌html多行E    多行代码行C      表格E|ERR             列表E|ERR

    fn @"Fn处理上一行"(self: *@"Tprogdoc格式转换状态机") !void {
        switch (self.@"上一行状态") {
            .@"多行代码行C" => {
                switch (self.@"当前行类别") {
                    .@"多行代码S" => {
                        return progdoc_err.@"当前行是多行代码行S但上一行状态是多行代码行C";
                    },
                    .@"多行代码SE" => {
                        self.@"当前行状态" = .@"多行代码行E";
                    },
                    else => {
                        self.@"当前行状态" = .@"多行代码行C";
                    },
                }
            },
            .@"无后续影响" => {
                switch (self.@"当前行类别") {
                    .@"多行代码S", .@"多行代码SE" => {
                        self.@"当前行状态" = .@"多行代码行S";
                    },
                    .@"标题行" => {
                        self.@"当前行状态" = .@"标题行";
                    },
                    .@"单行列表行", .@"多行列表行S" => {
                        self.@"当前行状态" = .@"列表S";
                    },
                    .@"多行列表行E" => {
                        return progdoc_err.@"多行列表行结束行没有对应的开始行";
                    },
                    .@"单行表格行", .@"多行表格行SE" => {
                        self.@"当前行状态" = .@"表格S";
                    },
                    .@"格式正文行" => {
                        self.@"当前行状态" = .@"格式正文行";
                    },
                    .@"内嵌html多行S" => {
                        self.@"当前行状态" = .@"内嵌html多行S";
                    },
                    .@"内嵌html多行E" => {
                        return progdoc_err.@"内嵌html结束行没有对应的开始行";
                    },
                }
            },
            .@"列表C" => {
                switch (self.@"当前行类别") {
                    .@"格式正文行" => {
                        const e = try self.@"文档列表栈".get();
                        if (e.@"上一行列表类别" == .@"列表开始单行") {
                            try self.@"Fn列表E"();
                            self.@"当前行状态" = .@"格式正文行";
                        } else {
                            self.@"当前行状态" = .@"列表C";
                        }
                    },
                    .@"单行列表行", .@"多行列表行S", .@"多行列表行E" => {
                        self.@"当前行状态" = .@"列表C";
                    },
                    .@"多行代码S", .@"多行代码SE" => {
                        try self.@"Fn列表E"();
                        self.@"当前行状态" = .@"多行代码行S";
                    },
                    .@"标题行" => {
                        try self.@"Fn列表E"();
                        self.@"当前行状态" = .@"标题行";
                    },
                    .@"单行表格行", .@"多行表格行SE" => {
                        try self.@"Fn列表E"();
                        self.@"当前行状态" = .@"表格S";
                    },
                    .@"内嵌html多行S" => {
                        try self.@"Fn列表E"();
                        self.@"当前行状态" = .@"内嵌html多行S";
                    },
                    .@"内嵌html多行E" => {
                        try self.@"Fn列表E"();
                        return progdoc_err.@"内嵌html结束行没有对应的开始行";
                    },
                }
            },
            .@"表格C" => {
                switch (self.@"当前行类别") {
                    .@"格式正文行" => {
                        try self.@"Fn表格E"();
                        self.@"当前行状态" = .@"格式正文行";
                    },
                    .@"单行列表行", .@"多行列表行S" => {
                        try self.@"Fn表格E"();
                        self.@"当前行状态" = .@"列表S";
                    },
                    .@"多行列表行E" => {
                        try self.@"Fn表格E"();
                        return progdoc_err.@"多行列表行结束行没有对应的开始行";
                    },
                    .@"多行代码S", .@"多行代码SE" => {
                        try self.@"Fn列表E"();
                        self.@"当前行状态" = .@"多行代码行S";
                    },
                    .@"标题行" => {
                        try self.@"Fn表格E"();
                        self.@"当前行状态" = .@"标题行";
                    },
                    .@"单行表格行", .@"多行表格行SE" => {
                        self.@"当前行状态" = .@"表格C";
                    },
                    .@"内嵌html多行S" => {
                        try self.@"Fn表格E"();
                        self.@"当前行状态" = .@"内嵌html多行S";
                    },
                    .@"内嵌html多行E" => {
                        try self.@"Fn表格E"();
                        return progdoc_err.@"内嵌html结束行没有对应的开始行";
                    },
                }
            },
            .@"内嵌html多行C" => {
                switch (self.@"当前行类别") {
                    .@"内嵌html多行S" => {
                        return progdoc_err.@"当前行是内嵌html多行S但上一行状态是内嵌html多行C";
                    },
                    .@"内嵌html多行E" => {
                        self.@"当前行状态" = .@"内嵌html多行E";
                    },
                    else => {
                        self.@"当前行状态" = .@"内嵌html多行C";
                    },
                }
            },
        }
    }

    //如果有BBB（文件名后缀），则设X="BBB-cap" , Y="file"
    //如果无BBB，则设X="AAA-cap" , Y=AAA
    //<figure>
    // <figcaption class="X">
    //  <cite class="Y">AAA.BBB</cite>
    // </figcaption>
    //<pre><code>
    //多行代码行开始处理
    pub fn @"Fn多行代码行S"(self: *@"Tprogdoc格式转换状态机") !void {
        var @"名字开始": usize = undefined;
        var @"后缀开始": usize = undefined;
        var @"后缀结束": usize = undefined;
        var X: []const u8 = undefined;
        var Y: []const u8 = undefined;
        var Z: []const u8 = undefined;
        if (@"Fn当前行查找不是ch的字符"(self.in, self.index, ' ', &@"名字开始")) {
            if (@"Fn当前行查找字符"(self.in, @"名字开始", '.', &@"后缀开始")) {
                @"后缀开始" += 1;
                _ = @"Fn当前行查找字符"(self.in, @"后缀开始", ' ', &@"后缀结束");
                X = self.in[@"后缀开始"..@"后缀结束"];
                Y = "file";
                Z = self.in[@"名字开始"..@"后缀结束"];
            } else {
                X = self.in[@"名字开始"..@"后缀开始"];
                Y = X;
                Z = X;
            }
        } else {
            X = "";
            Y = "";
            Z = "";
        }
        try self.out.writer().print("<figure>\r\n\t<figcaption class=\"{s}-cap\">\r\n", .{X});
        try self.out.writer().print("\t\t<cite class=\"{s}\">{s}", .{ Y, Z });
        try self.out.appendSlice("</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
        while (self.index < self.in.len) : (self.index += 1) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                break;
            }
        }
        self.@"上一行状态" = .@"多行代码行C";
    }
    //<span class="line">AAA</span>\r\n
    //每一代码行的处理
    //DEBUG:index要设成当前行开始索引，因为判断行类别时，吃掉了格式前导字符
    pub fn @"Fn多行代码行C"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<span class=\"line\">");
        self.index = self.@"当前行开始索引";
        while (self.index < self.in.len) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                break;
            }
            try @"Fn无格式正文字符"(self);
        }
        try self.out.appendSlice("</span>\r\n");
    }

    //</code></pre></figure>
    //多行代码行结尾
    pub fn @"Fn多行代码行E"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("</code></pre></figure>\r\n");
        self.@"上一行状态" = .@"无后续影响";
    }

    //解析一行，直到行尾或输入尾部。
    pub fn parseline(self: *@"Tprogdoc格式转换状态机") !void {
        if (self.index == self.in.len) {
            self.@"is输入尾部" = true;
            return;
        }
        errdefer |e| {
            print("解析出错：{s}\n错误位置第{}行，第{}个字符\n出错行：{s}\n", .{ @errorName(e), self.@"行号", self.index - self.@"当前行开始索引", self.in[self.@"当前行开始索引"..self.index] });
        }
        self.@"Fn判断当前行类别"();
        try self.@"Fn处理上一行"();
        switch (self.@"当前行状态") {
            .@"格式正文行" => {
                try self.@"Fn格式正文行"();
            },
            .@"标题行" => {
                try @"Fn标题行"(self);
            },
            .@"多行代码行S" => {
                try self.@"Fn多行代码行S"();
            },
            .@"多行代码行C" => {
                try self.@"Fn多行代码行C"();
            },
            .@"多行代码行E" => {
                try self.@"Fn多行代码行E"();
            },
            .@"列表S" => {
                try self.@"Fn列表S"();
            },
            .@"列表C" => {
                try self.@"Fn列表C"();
            },
            .@"表格S" => {
                try self.@"Fn表格S"();
            },
            .@"表格C" => {
                try self.@"Fn表格C"();
            },
            .@"内嵌html多行S" => {
                try self.@"Fn内嵌html多行S"();
            },
            .@"内嵌html多行C" => {
                try self.@"Fn内嵌html多行C"();
            },
            .@"内嵌html多行E" => {
                try self.@"Fn内嵌html多行E"();
            },
        }
        const i = @"Fnis包含字符串"(self.in, &self.index, .{ "\r\n", "\r", "\n" });
        if (i == -1) {
            self.@"is输入尾部" = true;
        }
        self.@"当前行开始索引" = self.index;
        self.@"行号" += 1;
    }

    // #<<
    // 内嵌html多行的开始处理
    pub fn @"Fn内嵌html多行S"(self: *@"Tprogdoc格式转换状态机") !void {
        self.@"Fn到行尾"();
        self.@"上一行状态" = .@"内嵌html多行C";
    }

    // 不进行任何实体替换或其它处理，原样输出内嵌html行
    pub fn @"Fn内嵌html多行C"(self: *@"Tprogdoc格式转换状态机") !void {
        while (self.index < self.in.len) : (self.index += 1) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                break;
            }
            try self.out.append(self.in[self.index]);
        }
    }

    // #>>
    // 内嵌html结束处理
    pub fn @"Fn内嵌html多行E"(self: *@"Tprogdoc格式转换状态机") !void {
        self.@"Fn到行尾"();
        self.@"上一行状态" = .@"无后续影响";
    }

    //单行列表项要加 </li>
    pub inline fn @"Fn单行列表行列表项"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<li>");
        try @"Fn格式正文C"(self, false);
        try self.out.appendSlice("</li>\r\n");
    }
    //多行列表项开始 <li> ，结尾没有 </li>
    //多行列表项与单行列表项的区别还有，要加<span>
    pub inline fn @"Fn多行列表行列表项"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<li><span>");
        try @"Fn格式正文C"(self, false);
        try self.out.appendSlice("</span>\r\n");
    }
    //多行正文项开始没有 <li>
    pub inline fn @"Fn多行列表行格式正文C"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<span>");
        try @"Fn格式正文C"(self, false);
        try self.out.appendSlice("</span>\r\n");
    }

    //列表开始处理
    //状态表
    //单行列表行    push(列表开始单行,单行列表行C)      单行列表项
    //多行列表行S   push(列表开始多行,多行列表行正文项)  多行列表项
    pub fn @"Fn列表S"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"文档列表栈";
        assert(stack.*.isempty());
        switch (self.@"当前行类别") {
            .@"单行列表行" => {
                try self.out.appendSlice("<ul>\r\n");
                try stack.*.push(.@"列表开始单行", .@"单行列表行C");
                try self.@"Fn单行列表行列表项"();
            },
            .@"多行列表行S" => {
                try self.out.appendSlice("<ul>\r\n");
                try stack.*.push(.@"列表开始多行2", .@"多行列表行正文项");
                try self.@"Fn多行列表行列表项"();
            },
            else => {
                unreachable;
            },
        }
        self.@"上一行状态" = .@"列表C";
    }

    //列表处理
    //状态表
    //             多行正文项                            单行C
    //单行列表行    <ul>|set(单行C)|单行列表项             单行列表项
    //多行列表行S   push(多行2,多行正文项)|<ul>|多行列表项   push(多行1,多行正文项)|多行列表项
    //格式正文行    <br />|多行正文                       </ul>|set(多行正文项)|多行正文

    //多行列表行E   if 列表开始单行             ERR
    //             if 单行C                 </ul>
    //             </li>
    //             if 多行2 or 列表开始多行   </ul>
    //              pop
    //             if isempty               无后续影响
    pub fn @"Fn列表C"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"文档列表栈";
        const e = try stack.*.get();
        switch (self.@"当前行类别") {
            .@"单行列表行" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try self.out.appendSlice("<ul>\r\n");
                    try stack.*.set(.@"单行列表行C");
                }
                try @"Fn单行列表行列表项"(self);
            },
            .@"多行列表行S" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try stack.*.push(.@"多行列表行2", .@"多行列表行正文项");
                    try self.out.appendSlice("<ul>\r\n");
                } else {
                    try stack.*.push(.@"多行列表行1", .@"多行列表行正文项");
                }
                try @"Fn多行列表行列表项"(self);
            },
            .@"格式正文行" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try self.out.appendSlice("<br />");
                } else {
                    try self.out.appendSlice("</ul>\r\n");
                    try stack.*.set(.@"多行列表行正文项");
                }
                try @"Fn多行列表行格式正文C"(self);
            },
            .@"多行列表行E" => {
                if (e.@"上一行列表类别" == .@"列表开始单行") {
                    return progdoc_err.@"多行列表行结束行没有对应的开始行";
                }
                if (e.@"上一行列表状态" == .@"单行列表行C") {
                    try self.out.appendSlice("</ul>\r\n");
                }
                try self.out.appendSlice("</li>\r\n");
                if (e.@"上一行列表类别" == .@"多行列表行2" or e.@"上一行列表类别" == .@"列表开始多行2") {
                    try self.out.appendSlice("</ul>\r\n");
                }
                try stack.*.pop();
                if (stack.*.isempty()) {
                    self.@"上一行状态" = .@"无后续影响";
                }
            },
            else => {
                unreachable;
            },
        }
    }

    //列表结束
    //上一行列表类别
    //列表开始单行  </ul>|pop|assert(isempty)|无后续影响
    //其它（多行类） ERR
    pub fn @"Fn列表E"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"文档列表栈";
        const e = try stack.*.get();
        switch (e.@"上一行列表类别") {
            .@"列表开始单行" => {
                try self.out.appendSlice("</ul>\r\n");
                try stack.*.pop();
                assert(stack.*.isempty());
                self.@"上一行状态" = .@"无后续影响";
            },
            else => {
                return progdoc_err.@"多行列表行没有对应的结束行";
            },
        }
    }

    //主要是为了区分普通正文和列表用
    pub fn @"Fn判断表格单元格类别"(self: *@"Tprogdoc格式转换状态机") void {
        var i = self.index;
        while (i < self.in.len) : (i += 1) {
            if (self.in[i] != ' ' and self.in[i] != '\t') {
                break;
            }
            if (self.in[i] == '\n' or self.in[i] == '\r') {
                break;
            }
        }
        var j = @"Fnis包含字符串"(self.in, &i, .{ "#--\r", "#--\n", "#--#|", "#--", "#-" });
        switch (j) {
            0, 1 => {
                self.@"当前表格单元格类别" = .@"多行列表行E";
                i -= 1;
            },
            2 => {
                self.@"当前表格单元格类别" = .@"多行列表行E";
                i -= 2;
            },
            3 => {
                if (i == self.in.len) {
                    self.@"当前表格单元格类别" = .@"多行列表行E";
                } else {
                    self.@"当前表格单元格类别" = .@"多行列表行S";
                }
            },
            4 => {
                self.@"当前表格单元格类别" = .@"单行列表行";
            },
            else => {
                i = self.index;
                self.@"当前表格单元格类别" = .@"格式正文行";
            },
        }
        self.index = i;
    }

    // 从当前待解析字符位置到行尾或输入尾
    // 用于 #|- #<< 等行，忽略同一行的后面字符。
    pub fn @"Fn到行尾"(self: *@"Tprogdoc格式转换状态机") void {
        while (self.index < self.in.len) : (self.index += 1) {
            if (self.in[self.index] == '\n' or self.in[self.index] == '\r') {
                break;
            }
        }
    }

    //如果列号对应的列表栈为空，则表示当前没有列表。
    //单元格列表栈          空          非空
    //格式正文行            格正文C     if(列表开始单行) 格列表E|格正文C else 格列表C
    //单行列表、多行列表S    格列表S      格列表C
    //多行列表E             ERR         格列表C
    pub fn @"Fn填写表格单元格内容"(self: *@"Tprogdoc格式转换状态机") !void {
        const e = self.@"表格单元格列表栈".items[self.@"表格当前列序号"].isempty();
        switch (self.@"当前表格单元格类别") {
            .@"格式正文行" => {
                if (e) {
                    try self.@"Fn表格单元格格式正文C"();
                } else {
                    const i = try self.@"表格单元格列表栈".items[self.@"表格当前列序号"].get();
                    if (i.@"上一行列表类别" == .@"列表开始单行") {
                        try self.@"Fn表格单元格列表E"();
                        try self.@"Fn表格单元格格式正文C"();
                    } else {
                        try self.@"Fn表格单元格列表C"();
                    }
                }
            },
            .@"单行列表行", .@"多行列表行S" => {
                if (e) {
                    try self.@"Fn表格单元格列表S"();
                } else {
                    try self.@"Fn表格单元格列表C"();
                }
            },
            .@"多行列表行E" => {
                if (e) {
                    return progdoc_err.@"多行列表行结束行没有对应的开始行";
                } else {
                    try self.@"Fn表格单元格列表C"();
                }
            },
        }
    }

    //表格S状态表
    //                动作          上一行表格状态
    //单行表格行     Fn表格开始单行     单行表格行C
    //多行表格行SE   Fn到行尾          多行表格开始行
    pub fn @"Fn表格S"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<table>\r\n");
        switch (self.@"当前行类别") {
            .@"单行表格行" => {
                try self.@"Fn表格开始单行"();
                self.@"上一行表格状态" = .@"单行表格行C";
            },
            .@"多行表格行SE" => {
                self.@"Fn到行尾"();
                self.@"上一行表格状态" = .@"多行表格开始行";
            },
            else => {
                unreachable;
            },
        }
        self.@"上一行状态" = .@"表格C";
    }

    //          单行表格行C                   多行表格开始行    多行表格行开始行    多行表格行C
    //单行表格行  Fn表格行单行C                Fn表格开始多行    F表格行多行S      Fn表格行多行C
    //多行表格SE            Fn到行尾
    //          上一行表格状态:多行表格开始行     ERR           ERR              Fn表格行多行E
    pub fn @"Fn表格C"(self: *@"Tprogdoc格式转换状态机") !void {
        switch (self.@"当前行类别") {
            .@"单行表格行" => {
                switch (self.@"上一行表格状态") {
                    .@"单行表格行C" => {
                        try self.@"Fn表格行单行C"();
                    },
                    .@"多行表格开始行" => {
                        try self.@"Fn表格开始多行"();
                    },
                    .@"多行表格行开始行" => {
                        try self.@"Fn表格行多行S"();
                    },
                    .@"多行表格行C" => {
                        try self.@"Fn表格行多行C"();
                    },
                }
            },
            .@"多行表格行SE" => {
                @"Fn到行尾"(self);
                switch (self.@"上一行表格状态") {
                    .@"单行表格行C" => {
                        self.@"上一行表格状态" = .@"多行表格行开始行";
                    },
                    .@"多行表格开始行", .@"多行表格行开始行" => {
                        return progdoc_err.@"多行表格行是空行";
                    },
                    .@"多行表格行C" => {
                        try self.@"Fn表格行多行E"();
                    },
                }
            },
            else => {
                unreachable;
            },
        }
    }

    //清空表格单元格列表栈、多行表格行缓冲、表格总列数、当前表格单元格类别、上一行表格状态等。
    //DEBUG:把.@"单元格"长度清0了。
    pub fn @"Fn表格E"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("</table>\r\n");
        self.@"上一行状态" = .@"无后续影响";
        self.@"表格单元格列表栈".items.len = 0;
        self.@"多行表格行缓冲".@"使用长度" = 0;
        self.@"表格总列数" = 0;
        self.@"当前表格单元格类别" = undefined;
        self.@"上一行表格状态" = undefined;
    }

    pub inline fn @"Fn表格单元格格式正文C"(self: *@"Tprogdoc格式转换状态机") !void {
        try @"Fn格式正文C"(self, true);
    }
    pub inline fn @"Fn表格单元格单行列表行列表项"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<li>");
        try @"Fn格式正文C"(self, true);
        try self.out.appendSlice("</li>\r\n");
    }
    pub inline fn @"Fn表格单元格多行列表行列表项"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<li><span>");
        try @"Fn格式正文C"(self, true);
        try self.out.appendSlice("</span>\r\n");
    }
    pub inline fn @"Fn表格单元格多行列表行格式正文C"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<span>");
        try @"Fn格式正文C"(self, true);
        try self.out.appendSlice("</span>\r\n");
    }

    //格单列表行    <ul>|push(开始单行，单行C)|格单行列表项
    //格多列表行S   <ul>|push(开始多行2，正文项)|格多行列表项
    pub fn @"Fn表格单元格列表S"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"表格单元格列表栈".items[self.@"表格当前列序号"];
        assert(stack.*.isempty());
        switch (self.@"当前表格单元格类别") {
            .@"单行列表行" => {
                try self.out.appendSlice("<ul>\r\n");
                try stack.*.push(.@"列表开始单行", .@"单行列表行C");
                try self.@"Fn表格单元格单行列表行列表项"();
            },
            .@"多行列表行S" => {
                try self.out.appendSlice("<ul>\r\n");
                try stack.*.push(.@"列表开始多行2", .@"多行列表行正文项");
                try self.@"Fn表格单元格多行列表行列表项"();
            },
            else => {
                unreachable;
            },
        }
    }

    //            格多行正文项                        格单行C
    //格单行列表    <ul>|set(单行C)|格单行列表项          格单行列表项
    //格多行列表S   push(多行2,正文)|<ul>|格多行列表项     push(多行1,正文)|格多行列表项
    //格正文       <br />|格正文                        </ul>|set(正文)|格正文

    //格多行E       if 表格开始单行           ERR
    //             if 单行C                 </ul>
    //             </li>
    //             if 多行2 or 列表开始多行   </ul>
    //              pop
    pub fn @"Fn表格单元格列表C"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"表格单元格列表栈".items[self.@"表格当前列序号"];
        const e = try stack.*.get();
        switch (self.@"当前表格单元格类别") {
            .@"单行列表行" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try self.out.appendSlice("<ul>\r\n");
                    try stack.*.set(.@"单行列表行C");
                }
                try self.@"Fn表格单元格单行列表行列表项"();
            },
            .@"多行列表行S" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try stack.*.push(.@"多行列表行2", .@"多行列表行正文项");
                    try self.out.appendSlice("<ul>\r\n");
                } else {
                    try stack.*.push(.@"多行列表行1", .@"多行列表行正文项");
                }
                try self.@"Fn表格单元格多行列表行列表项"();
            },
            .@"格式正文行" => {
                if (e.@"上一行列表状态" == .@"多行列表行正文项") {
                    try self.out.appendSlice("<br />");
                } else {
                    try self.out.appendSlice("</ul>\r\n");
                    try stack.*.set(.@"多行列表行正文项");
                }
                try self.@"Fn表格单元格多行列表行格式正文C"();
            },
            .@"多行列表行E" => {
                if (e.@"上一行列表类别" == .@"列表开始单行") {
                    return progdoc_err.@"多行列表行结束行没有对应的开始行";
                }
                if (e.@"上一行列表状态" == .@"单行列表行C") {
                    try self.out.appendSlice("</ul>\r\n");
                }
                try self.out.appendSlice("</li>\r\n");
                if (e.@"上一行列表类别" == .@"多行列表行2" or e.@"上一行列表类别" == .@"列表开始多行2") {
                    try self.out.appendSlice("</ul>\r\n");
                }
                try stack.*.pop();
            },
        }
    }

    //列表开始单行  </ul>|pop|assert(isempty)
    //其它（多行类） ERR
    pub fn @"Fn表格单元格列表E"(self: *@"Tprogdoc格式转换状态机") !void {
        var stack = &self.@"表格单元格列表栈".items[self.@"表格当前列序号"];
        const e = try stack.*.get();
        switch (e.@"上一行列表类别") {
            .@"列表开始单行" => {
                try self.out.appendSlice("</ul>\r\n");
                try stack.*.pop();
                assert(stack.*.isempty());
            },
            else => {
                return progdoc_err.@"多行列表行没有对应的结束行";
            },
        }
    }

    //开始行要处理对齐，设定总列数，单元格列表栈要搞到总列数数量。
    //< 单元格左对齐    > 单元格右对齐    ^ 单元格居中
    pub fn @"Fn表格开始单行"(self: *@"Tprogdoc格式转换状态机") !void {
        self.@"上一行表格状态" = .@"单行表格行C";
        try self.out.appendSlice("<tr>\r\n");
        while (self.index < self.in.len) {
            try self.@"表格单元格列表栈".append(.{});
            var i = @"Fnis包含字符串"(self.in, &self.index, .{ "<", ">", "^" });
            var @"对齐str": []const u8 = undefined;
            if (i != -1) {
                @"对齐str" = switch (i) {
                    0 => "t_left",
                    1 => "t_right",
                    2 => "t_center",
                    else => "",
                };
                try self.out.writer().print("<td class=\"{s}\">", .{@"对齐str"});
            } else {
                try self.out.appendSlice("<td>");
            }
            try self.@"Fn表格单元格格式正文C"();
            try self.out.appendSlice("</td>\r\n");
            self.@"表格当前列序号" += 1;
            if (self.index == self.in.len) {
                break;
            }
            i = @"Fnis包含字符串"(self.in, &self.index, .{ "#|", "\r", "\n" });
            assert(i != -1);
            if (i != 0) {
                self.index -= 1;
                break;
            }
        }
        try self.out.appendSlice("</tr>\r\n");
        self.@"表格总列数" = self.@"表格当前列序号";
        self.@"表格当前列序号" = 0;
    }

    //单行C要处理每行的对齐。
    //如果当前列数不等于总列数，则ERR
    pub fn @"Fn表格行单行C"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice("<tr>\r\n");
        while (self.index < self.in.len) {
            var i = @"Fnis包含字符串"(self.in, &self.index, .{ "<", ">", "^" });
            var @"对齐str": []const u8 = undefined;
            if (i != -1) {
                @"对齐str" = switch (i) {
                    0 => "t_left",
                    1 => "t_right",
                    2 => "t_center",
                    else => "",
                };
                try self.out.writer().print("<td class=\"{s}\">", .{@"对齐str"});
            } else {
                try self.out.appendSlice("<td>");
            }
            try self.@"Fn表格单元格格式正文C"();
            try self.out.appendSlice("</td>\r\n");
            self.@"表格当前列序号" += 1;
            if (self.index == self.in.len) {
                break;
            }
            i = @"Fnis包含字符串"(self.in, &self.index, .{ "#|", "\r", "\n" });
            assert(i != -1);
            if (i != 0) {
                self.index -= 1;
                break;
            }
        }
        if (self.@"表格当前列序号" != self.@"表格总列数") {
            return progdoc_err.@"与上一行表格列数不相等";
        }
        try self.out.appendSlice("</tr>\r\n");
        self.@"表格当前列序号" = 0;
    }

    //开始行要处理对齐，设定总列数，单元格列表栈、多行缓冲要搞到总列数数量。
    //多行每个单元格要切换out，以输出到多行缓冲二维动态数组中。
    pub fn @"Fn表格开始多行"(self: *@"Tprogdoc格式转换状态机") !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var al = arena.allocator();
        self.@"上一行表格状态" = .@"多行表格行C";
        try self.out.appendSlice("<tr>\r\n");
        const x = self.out;
        while (self.index < self.in.len) {
            try self.@"表格单元格列表栈".append(.{});
            try self.@"多行表格行缓冲".@"Fn增加多行表格行单元格缓冲"(al);
            var i = @"Fnis包含字符串"(self.in, &self.index, .{ "<", ">", "^" });
            var @"对齐str": []const u8 = undefined;
            self.@"多行表格temp".items.len = 0;
            self.out = self.@"多行表格temp";
            if (i != -1) {
                @"对齐str" = switch (i) {
                    0 => "t_left",
                    1 => "t_right",
                    2 => "t_center",
                    else => "",
                };
                try self.out.writer().print("<td class=\"{s}\">", .{@"对齐str"});
            } else {
                try self.out.appendSlice("<td>");
            }
            self.@"Fn判断表格单元格类别"();
            try self.@"Fn填写表格单元格内容"();
            try self.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(self.@"表格当前列序号", self.out.items);
            self.@"表格当前列序号" += 1;
            if (self.index == self.in.len) {
                break;
            }
            i = @"Fnis包含字符串"(self.in, &self.index, .{ "#|", "\r", "\n" });
            assert(i != -1);
            if (i != 0) {
                self.index -= 1;
                break;
            }
        }
        self.out = x;
        self.@"表格总列数" = self.@"表格当前列序号";
        self.@"表格当前列序号" = 0;
    }

    //多行表格行的后续行对齐无用，不处理对齐，以第1行为准。
    //多行表格行的后续行单元格不加<td>
    //如果当前列数不等于总列数，则ERR
    pub fn @"Fn表格行多行C"(self: *@"Tprogdoc格式转换状态机") !void {
        const x = self.out;
        while (self.index < self.in.len) {
            self.@"多行表格temp".items.len = 0;
            self.out = self.@"多行表格temp";
            if (self.@"表格单元格列表栈".items[self.@"表格当前列序号"].isempty()) {
                try self.out.appendSlice("<br />");
            }
            self.@"Fn判断表格单元格类别"();
            try self.@"Fn填写表格单元格内容"();
            try self.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(self.@"表格当前列序号", self.out.items);
            self.@"表格当前列序号" += 1;
            if (self.index == self.in.len) {
                break;
            }
            var i = @"Fnis包含字符串"(self.in, &self.index, .{ "#|", "\r", "\n" });
            assert(i != -1);
            if (i != 0) {
                self.index -= 1;
                break;
            }
        }
        if (self.@"表格当前列序号" != self.@"表格总列数") {
            return progdoc_err.@"与上一行表格列数不相等";
        }
        self.@"表格当前列序号" = 0;
        self.out = x;
    }

    //表格中间，多行S要处理对齐，每1个单元格前要加<td>
    //注意要判断是否多行缓冲是空，空的话则增加。
    pub fn @"Fn表格行多行S"(self: *@"Tprogdoc格式转换状态机") !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var al = arena.allocator();
        if (self.@"多行表格行缓冲".@"使用长度" == 0) {
            var i: usize = 0;
            while (i < self.@"表格总列数") : (i += 1) {
                try self.@"多行表格行缓冲".@"Fn增加多行表格行单元格缓冲"(al);
            }
        }
        self.@"上一行表格状态" = .@"多行表格行C";
        try self.out.appendSlice("<tr>\r\n");
        const x = self.out;
        while (self.index < self.in.len) {
            self.@"多行表格temp".items.len = 0;
            self.out = self.@"多行表格temp";
            var i = @"Fnis包含字符串"(self.in, &self.index, .{ "<", ">", "^" });
            var @"对齐str": []const u8 = undefined;
            if (i != -1) {
                @"对齐str" = switch (i) {
                    0 => "t_left",
                    1 => "t_right",
                    2 => "t_center",
                    else => "",
                };
                try self.out.writer().print("<td class=\"{s}\">", .{@"对齐str"});
            } else {
                try self.out.appendSlice("<td>");
            }
            self.@"Fn判断表格单元格类别"();
            try self.@"Fn填写表格单元格内容"();
            try self.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(self.@"表格当前列序号", self.out.items);
            self.@"表格当前列序号" += 1;
            if (self.index == self.in.len) {
                break;
            }
            var j = @"Fnis包含字符串"(self.in, &self.index, .{ "#|", "\r", "\n" });
            assert(j != -1);
            if (j != 0) {
                self.index -= 1;
                break;
            }
        }
        if (self.@"表格当前列序号" != self.@"表格总列数") {
            return progdoc_err.@"与上一行表格列数不相等";
        }
        self.@"表格当前列序号" = 0;
        self.out = x;
    }

    //多行结束，每单元格后加</td>；将多行缓冲追加到out输出；清空多行缓冲。
    //DEBUG：多行结束时没有判断单元格列表结束与否。
    //DEBUG:循环变量原来用的是i,而不是表格当前列序号
    pub fn @"Fn表格行多行E"(self: *@"Tprogdoc格式转换状态机") !void {
        self.@"上一行表格状态" = .@"单行表格行C";
        try self.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲全部追加字符串"("</td>\r\n");
        while (self.@"表格当前列序号" < self.@"表格总列数") : (self.@"表格当前列序号" += 1) {
            if (!self.@"表格单元格列表栈".items[self.@"表格当前列序号"].isempty()) {
                try self.@"Fn表格单元格列表E"();
            }
            var x = try self.@"多行表格行缓冲".@"Fn获取多行表格行单元格缓冲"(self.@"表格当前列序号");
            try self.out.appendSlice(x.items);
        }
        try self.out.appendSlice("</tr>\r\n");
        self.@"多行表格行缓冲".@"Fn清空多行表格行单元格缓冲"();
        for (self.@"表格单元格列表栈".items) |v| {
            assert(v.isempty());
        }
        self.@"表格当前列序号" = 0;
    }

    fn @"Fn文件头"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice(html.htmlhead);
        self.@"插入目录位置" = self.out.items.len;
        try self.out.appendSlice(html.htmlhead1);
    }

    fn setStyle(self: *@"Tprogdoc格式转换状态机") !void {
        try self.out.appendSlice(html.style);
    }

    fn @"Fn文件尾"(self: *@"Tprogdoc格式转换状态机") !void {
        try self.@"目录".appendSlice("</ul>\r\n</div>\r\n");
        try self.out.insertSlice(self.@"插入目录位置", self.@"目录".items);
        try self.out.appendSlice(html.htmlend);
    }

    fn @"Fn文件结尾状态处理"(self: *@"Tprogdoc格式转换状态机") !void {
        switch (self.@"上一行状态") {
            .@"多行代码行C" => {
                return progdoc_err.@"多行代码没有结束行";
            },
            .@"内嵌html多行C" => {
                return progdoc_err.@"内嵌html多行没有结束行";
            },
            .@"列表C" => {
                try self.@"Fn列表E"();
            },
            .@"表格C" => {
                try self.@"Fn表格E"();
            },
            .@"无后续影响" => {},
        }
    }

    pub fn parseProgdoc(self: *@"Tprogdoc格式转换状态机") !void {
        try self.@"Fn文件头"();
        while (!self.@"is输入尾部") {
            try self.parseline();
        }
        try self.@"Fn文件结尾状态处理"();
        try self.@"Fn文件尾"();
    }

    pub fn parseProgdoc2(self: *@"Tprogdoc格式转换状态机") !void {
        try self.setStyle();
        while (!self.@"is输入尾部") {
            try self.parseline();
        }
        try self.@"Fn文件结尾状态处理"();
    }
};

// 列表栈操作，列表栈长度固定为7，一方面占用内存极小不用再省了，一方面7层级列表足够用了。层级太多需要整理思路重新写。
// 第一级列表在列表栈[0]，第二级列表在[1]，依此类推。
// 当列表栈isempty时，表明列表正确结束。
// 当前列表中，多行列表行S则压栈，增加1级，多行列表行E则出栈，减少1级。
// 列表栈[0]较特殊，只有 列表开始单行 和 列表开始多行2 两种类别，因为对应的是整个列表的开始。
const @"列表栈长度": usize = 7;
const @"T列表栈" = struct {
    top: i4 = -1,
    entry: [@"列表栈长度"]@"T列表栈项" = undefined,
    fn push(self: *@"T列表栈", a: @"T上一行列表类别", b: @"T上一行列表状态") !void {
        self.top += 1;
        if (self.top == @"列表栈长度") {
            return progdoc_err.@"push时列表栈满";
        }
        self.entry[@intCast(usize, self.top)].@"上一行列表类别" = a;
        self.entry[@intCast(usize, self.top)].@"上一行列表状态" = b;
    }
    fn pop(self: *@"T列表栈") !void {
        if (self.top == -1) {
            return progdoc_err.@"pop时列表栈空";
        }
        self.top -= 1;
    }
    fn get(self: @"T列表栈") !@"T列表栈项" {
        if (self.top == -1) {
            return progdoc_err.@"get时列表栈空";
        }
        return self.entry[@intCast(usize, self.top)];
    }
    fn set(self: *@"T列表栈", b: @"T上一行列表状态") !void {
        if (self.top == -1) {
            return progdoc_err.@"set时列表栈空";
        }
        self.entry[@intCast(usize, self.top)].@"上一行列表状态" = b;
    }
    fn empty(self: *@"T列表栈") void {
        self.top = -1;
    }
    fn isempty(self: @"T列表栈") bool {
        return self.top == -1;
    }
};
const @"T列表栈项" = packed struct {
    @"上一行列表类别": @"T上一行列表类别",
    @"上一行列表状态": @"T上一行列表状态",
};
const @"T上一行列表类别" = enum(u2) {
    @"列表开始单行", //整个列表的开始行，是#-
    @"列表开始多行2", //整个列表的开始行，是#--
    @"多行列表行1", // 1是在单行列表行后面，不需要 <ul>
    @"多行列表行2", // 2是在列表正文后，需要 <ul>
};
const @"T上一行列表状态" = enum(u2) {
    @"单行列表行C",
    @"多行列表行正文项",
};

// 因表格总列数和表格单元格字符数根据实际输入来定，不能在编译期确定，所以设计了简陋的二维动态数组数据结构。
// 多行表格行缓冲
pub const MultiRowTableBuffer = struct {
    @"单元格": std.ArrayList(std.ArrayList(u8)),
    @"使用长度": usize = 0,
    @"容量": usize = 0,

    pub fn createMultiRowTableBuf(al: std.mem.Allocator) !MultiRowTableBuffer {
        const c = try std.ArrayList(std.ArrayList(u8)).initCapacity(al, 10);
        var r: MultiRowTableBuffer = .{ .@"单元格" = c, .@"容量" = 10 };
        var i: usize = 0;
        r.@"使用长度" = 0;
        while (i < r.@"容量") : (i += 1) {
            var j = try std.ArrayList(u8).initCapacity(al, 80);
            try r.@"单元格".append(j);
        }
        return r;
    }
    fn @"Fn获取多行表格行单元格缓冲"(self: *MultiRowTableBuffer, @"序号": usize) !std.ArrayList(u8) {
        if (@"序号" >= self.@"使用长度") {
            return progdoc_err.@"多行表格行缓冲溢出错误";
        }
        return self.@"单元格".items[@"序号"];
    }
    fn @"Fn多行表格行单元格缓冲追加字符串"(self: *MultiRowTableBuffer, @"序号": usize, str: []const u8) !void {
        if (@"序号" >= self.@"使用长度") {
            return progdoc_err.@"多行表格行缓冲溢出错误";
        }
        try self.@"单元格".items[@"序号"].appendSlice(str);
    }
    fn @"Fn增加多行表格行单元格缓冲"(self: *MultiRowTableBuffer, al: std.mem.Allocator) !void {
        if (self.@"使用长度" >= self.@"容量") {
            var i = self.@"容量";
            self.@"容量" += 10;
            while (i < self.@"容量") : (i += 1) {
                var j = try std.ArrayList(u8).initCapacity(al, 80);
                try self.@"单元格".append(j);
            }
        } else {
            self.@"单元格".items[self.@"使用长度"].items.len = 0;
        }
        self.@"使用长度" += 1;
    }
    fn @"Fn清空多行表格行单元格缓冲"(self: *MultiRowTableBuffer) void {
        var i: usize = 0;
        while (i < self.@"使用长度") : (i += 1) {
            self.@"单元格".items[i].items.len = 0;
        }
    }
    fn @"Fn多行表格行单元格缓冲全部追加字符串"(self: *MultiRowTableBuffer, str: []const u8) !void {
        var i: usize = 0;
        while (i < self.@"使用长度") : (i += 1) {
            try self.@"单元格".items[i].appendSlice(str);
        }
    }
    pub fn delectMulitTableBuffer(r: *MultiRowTableBuffer) void {
        // var i:usize=0;
        for (r.@"单元格".items) |*v| {
            v.deinit();
        }
        r.@"单元格".deinit();
        r.@"容量" = 0;
        r.@"使用长度" = 0;
        r.@"单元格" = undefined;
    }
};

test "多行表格行缓冲" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();

    var mult = try MultiRowTableBuffer.createMultiRowTableBuf(al);
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        try mult.@"Fn增加多行表格行单元格缓冲"(al);
    }
    try expect(mult.@"容量" == 20);
    try expect(mult.@"使用长度" == 13);
    try expectError(progdoc_err.@"多行表格行缓冲溢出错误", mult.@"Fn获取多行表格行单元格缓冲"(13));

    try mult.@"Fn多行表格行单元格缓冲追加字符串"(0, "test");
    var x = try mult.@"Fn获取多行表格行单元格缓冲"(0);
    try expectEqualSlices(u8, x.items, "test");

    try mult.@"Fn多行表格行单元格缓冲追加字符串"(1, "test1");
    try mult.@"Fn多行表格行单元格缓冲追加字符串"(1, "test2");
    x = try mult.@"Fn获取多行表格行单元格缓冲"(1);
    try expectEqualSlices(u8, x.items, "test1test2");

    try mult.@"Fn多行表格行单元格缓冲全部追加字符串"("<end>");
    x = try mult.@"Fn获取多行表格行单元格缓冲"(0);
    try expectEqualSlices(u8, x.items, "test<end>");
    x = try mult.@"Fn获取多行表格行单元格缓冲"(1);
    try expectEqualSlices(u8, x.items, "test1test2<end>");
    x = try mult.@"Fn获取多行表格行单元格缓冲"(2);
    try expectEqualSlices(u8, x.items, "<end>");

    x = try mult.@"Fn获取多行表格行单元格缓冲"(10);
    try x.append('a');
    try x.append('b');
    try expectEqualSlices(u8, x.items, "<end>ab");
    mult.@"Fn清空多行表格行单元格缓冲"();
    try expect(mult.@"容量" == 20);
    mult.delectMulitTableBuffer();
}

// strs是编译期确定个数的字符串数组，从buf的第start个字符开始，按strs中的先后顺序，逐个和strs中的字符串比对。
// 如果找到任1个，start值增加找到字符串的长度。
// 找到第n个字符串，返回n；没找到，返回 -1。
// strs的顺序非常重要，调用时要考虑好了。如：
// .{"\r\n","\r","\n"} 可正确找出对应字符串，当有"\r\n"时，返回0。
// .{"\r","\r\n","\n"} 不能正确找出，当有"\r\n"时，返回0，而不是返回想要的1。
fn @"Fnis包含字符串"(buf: []const u8, start: *usize, comptime strs: anytype) i8 {
    inline for (strs) |str, i| {
        if (buf.len - start.* >= str.len) {
            for (str) |v, j| {
                if (v != buf[start.* + j]) {
                    break;
                }
            } else {
                start.* += str.len;
                return i;
            }
        }
    }
    return -1;
}

test "Fnis包含字符串" {
    var i: i8 = undefined;
    var s: usize = 0;
    i = @"Fnis包含字符串"("#| abc", &s, .{ "#-", "#--", "#|", "#|-" });
    try expect(i == 2);
    try expect(s == 2);

    s = 3;
    i = @"Fnis包含字符串"("1\r\n#| abc", &s, .{ "#-", "#--", "#|", "#|-" });
    try expect(i == 2);
    try expect(s == 5);

    s = 0;
    i = @"Fnis包含字符串"("#", &s, .{ "#-", "#--", "#|", "#|-" });
    try expect(i == -1);
    try expect(s == 0);

    s = 0;
    i = @"Fnis包含字符串"("#-", &s, .{ "#-", "#--", "#|", "#|-" });
    try expect(i == 0);
    try expect(s == 2);

    s = 0;
    i = @"Fnis包含字符串"("``\r", &s, .{ "```", "``\r", "``\n", "``", "`" });
    try expect(i == 1);
    try expect(s == 3);

    s = 0;
    i = @"Fnis包含字符串"("", &s, .{ "```", "``\r", "``\n", "``", "`" });
    try expect(i == -1);
    try expect(s == 0);
}

test "Fn判断当前行类别 内嵌html" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var al = arena.allocator();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#>>");
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"内嵌html多行E");
    try expect(s.index == 3);

    s.in = "#<<";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"内嵌html多行S");
    try expect(s.index == 3);

    s.@"Fn清空状态机"();
}

test "Fn判断当前行类别 多行代码S 多行代码SE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    s.in = "`";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "```";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码SE");
    try expect(s.index == 3);

    s.in = "``";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "```\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码SE");
    try expect(s.index == 3);

    s.in = "```\r\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码SE");
    try expect(s.index == 3);

    s.in = "````";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码S");
    try expect(s.index == 3);

    s.in = "``` hello.zig";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码S");
    try expect(s.index == 3);

    s.in = "012345\r\n```\r\n``` test.zig\r\n";
    s.@"当前行开始索引" = 8;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码SE");
    try expect(s.index == 11);

    s.@"当前行开始索引" = 13;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行代码S");
    try expect(s.index == 16);
    s.@"Fn清空状态机"();
}

test "Fn判断当前行类别 标题" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    s.in = "1";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = ".";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "1.";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 1);
    try expect(s.index == 2);

    s.in = "1.\r\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 1);
    try expect(s.index == 2);

    s.in = " 12.135..12";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "12.135..12";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 2);
    try expect(s.index == 7);

    s.in = "12.1.1.5. test";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 4);
    try expect(s.index == 9);

    s.in = "123456";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "0123\n1";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n.";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n1.\r\n";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 1);
    try expect(s.index == 7);

    s.in = "0123\n 12.135..12";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n12.135..12";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 2);
    try expect(s.index == 12);

    s.in = "0123\n12.1.1.5. test";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"标题行");
    try expect(s.@"标题级数" == 4);
    try expect(s.index == 14);

    s.in = "0123\n123456";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);
    s.@"Fn清空状态机"();
}

test "Fn判断当前行类别 表格行" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    s.in = "#";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "#advbdafs";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = " #|";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "#|";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行表格行");
    try expect(s.index == 2);

    s.in = "#|\r\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行表格行");
    try expect(s.index == 2);

    s.in = "#| adfsad ";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行表格行");
    try expect(s.index == 2);

    s.in = "#|-";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行表格行SE");
    try expect(s.index == 3);

    s.in = "#|----dd#|---";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行表格行SE");
    try expect(s.index == 3);

    s.in = "0123\n#";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n#advbdafs";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n #|";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n#|\r\n";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行表格行");
    try expect(s.index == 7);

    s.in = "0123\n#| adfsad ";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行表格行");
    try expect(s.index == 7);

    s.in = "0123\n#|-";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行表格行SE");
    try expect(s.index == 8);

    s.in = "0123\n#|----dd#|---";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行表格行SE");
    try expect(s.index == 8);
    s.@"Fn清空状态机"();
}

test "Fn判断当前行类别 列表行" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    s.in = "#-";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 2);

    s.in = "   abc\r\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "#-\r\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 2);

    s.in = "#- ";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 2);

    s.in = "#- aadf\n";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 2);

    s.in = "# -";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 0);

    s.in = "  \t  \t\t #- adfsaf";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 10);

    s.in = "#--";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 3);

    s.in = "#--\r\n adfaf";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 3);

    s.in = "  \t#--\r\n adfaf";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 6);

    s.in = "#-- adfaf";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行S");
    try expect(s.index == 3);

    s.in = "  #-- adfaf";
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行S");
    try expect(s.index == 5);

    s.in = "0123\n#-\r\n";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 7);

    s.in = "0123\n#- ";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 7);

    s.in = "0123\n#- aadf\n";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 7);

    s.in = "0123\n# -";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"格式正文行");
    try expect(s.index == 5);

    s.in = "0123\n  \t  \t\t #- adfsaf";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"单行列表行");
    try expect(s.index == 15);

    s.in = "0123\n#--";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 8);

    s.in = "0123\n#--\r\n adfaf";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 8);

    s.in = "0123\n  \t#--\r\n adfaf";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行E");
    try expect(s.index == 11);

    s.in = "0123\n#-- adfaf";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行S");
    try expect(s.index == 8);

    s.in = "0123\n  #-- adfaf";
    s.@"当前行开始索引" = 5;
    s.@"Fn判断当前行类别"();
    try expect(s.@"当前行类别" == .@"多行列表行S");
    try expect(s.index == 10);
    s.@"Fn清空状态机"();
}

test "Fn无格式正文字符" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "a<b>c#`d\n");
    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a");
    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a&lt;");

    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a&lt;b");

    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a&lt;b&gt;");

    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a&lt;b&gt;c");

    try s.@"Fn无格式正文字符"();
    try s.@"Fn无格式正文字符"();
    try s.@"Fn无格式正文字符"();
    try expectEqualSlices(u8, s.out.items, "a&lt;b&gt;c#`d");
    s.@"Fn清空状态机"();
}

test "Fn普通正文字符" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "t<>#`#e");
    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "t");
    try expect(s.index == 1);

    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "t&lt;");
    try expect(s.index == 2);

    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "t&lt;&gt;");
    try expect(s.index == 3);

    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "t&lt;&gt;`");
    try expect(s.index == 5);

    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "t&lt;&gt;`#");
    try expect(s.index == 6);

    s.in = "#`";
    s.out.items.len = 0;
    s.index = 0;
    try s.@"Fn普通正文字符"();
    try expectEqualSlices(u8, s.out.items, "`");
    try expect(s.index == 2);
    s.@"Fn清空状态机"();
}

test "Fn行代码" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "this ``");
    s.index = 7;
    try s.@"Fn行代码"();
    try expectEqualSlices(u8, s.out.items, "<code></code>");
    try expect(s.index == 7);

    s.in = "`` t<h#` #|";
    s.index = 2;
    s.out.items.len = 0;
    try s.@"Fn行代码"();
    try expectEqualSlices(u8, s.out.items, "<code> t&lt;h` #|</code>");
    try expect(s.index == 11);

    s.in = "``test#[#]\r\nthis is";
    s.index = 2;
    s.out.items.len = 0;
    try s.@"Fn行代码"();
    try expectEqualSlices(u8, s.out.items, "<code>test#[#]</code>");
    try expect(s.index == 10);
    s.@"Fn清空状态机"();
}

test "Fn短代码" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    try expectError(progdoc_err.@"短代码无结束`字符", s.@"Fn短代码"());

    s.in = "test\na`";
    try expectError(progdoc_err.@"短代码无结束`字符", s.@"Fn短代码"());

    s.in = "test";
    try expectError(progdoc_err.@"短代码无结束`字符", s.@"Fn短代码"());

    s.in = "a`test<#`>b`ccc\r\n";
    s.index = 2;
    s.out.items.len = 0;
    try s.@"Fn短代码"();
    try expectEqualSlices(u8, s.out.items, "<code>test&lt;`&gt;b</code>");
    try expect(s.index == 12);
    s.@"Fn清空状态机"();
}

test "Fn普通正文字符和短代码" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "a`\r\n``b<`te`b#`c");
    s.index = 1;
    try expectError(progdoc_err.@"短代码无结束`字符", s.@"Fn普通正文字符和短代码"());

    s.index = 4;
    try expectError(progdoc_err.@"短代码无结束`字符", s.@"Fn普通正文字符和短代码"());

    s.index = 6;
    s.out.items.len = 0;
    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b");
    try expect(s.index == 7);

    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b&lt;");

    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b&lt;<code>te</code>");
    try expect(s.index == 12);

    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b&lt;<code>te</code>b");

    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b&lt;<code>te</code>b`");

    try s.@"Fn普通正文字符和短代码"();
    try expectEqualSlices(u8, s.out.items, "b&lt;<code>te</code>b`c");
    s.@"Fn清空状态机"();
}

test "Fn内链" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "[[a");
    s.index = 2;
    try expectError(progdoc_err.@"内链无结束]]字符串", s.@"Fn内链"());

    s.in = "[[a\n";
    s.index = 2;
    try expectError(progdoc_err.@"内链无结束]]字符串", s.@"Fn内链"());

    s.in = "[[ab[[cd]]\n";
    s.index = 2;
    try expectError(progdoc_err.@"内链中含有[[字符串", s.@"Fn内链"());

    s.in = "[[1.1. abcd]]ee";
    s.index = 2;
    s.out.items.len = 0;
    try s.@"Fn内链"();
    try expectEqualSlices(u8, s.out.items, "<a href=\"#N1.1. abcd\">1.1. abcd</a>");
    try expect(s.index == 13);

    s.in = "[[1.1. `[[`a[bc]d]]ee";
    s.index = 2;
    s.out.items.len = 0;
    try s.@"Fn内链"();
    try expectEqualSlices(u8, s.out.items, "<a href=\"#N1.1. <code>[[</code>a[bc]d\">1.1. <code>[[</code>a[bc]d</a>");
    try expect(s.index == 19);
    s.@"Fn清空状态机"();
}

test "Fn外链" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#[ab");
    s.index = 2;
    try expectError(progdoc_err.@"外链说明无#](结束字符串", s.@"Fn外链"());

    s.in = "#[ab\n";
    s.index = 2;
    try expectError(progdoc_err.@"外链说明无#](结束字符串", s.@"Fn外链"());

    s.in = "#[ab#[\n";
    s.index = 2;
    try expectError(progdoc_err.@"外链说明中含有#[或#]字符串", s.@"Fn外链"());

    s.in = "#[ab#](http:(dd.com)\n";
    s.index = 2;
    try expectError(progdoc_err.@"外链链接中含有(字符", s.@"Fn外链"());

    s.in = "#[ab#](http://dd.com\n";
    s.index = 2;
    try expectError(progdoc_err.@"外链链接无)结束字符", s.@"Fn外链"());

    s.in = "this is #[progdoc homepage#](https://progdoc.com). \r\n";
    s.index = 10;
    s.out.items.len = 0;
    try s.@"Fn外链"();
    try expectEqualSlices(u8, s.out.items, "<a href=\"https://progdoc.com\">progdoc homepage</a>");

    s.in = "this is #[progdoc `[]` #](https://progdoc.com). \r\n";
    s.index = 10;
    s.out.items.len = 0;
    try s.@"Fn外链"();
    try expectEqualSlices(u8, s.out.items, "<a href=\"https://progdoc.com\">progdoc <code>[]</code> </a>");
    s.@"Fn清空状态机"();
}

test "Fn图片" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "!#[ab");
    s.index = 3;
    try expectError(progdoc_err.@"图片说明无#](结束字符串", s.@"Fn图片"());

    s.in = "!#[ab\n";
    s.index = 3;
    try expectError(progdoc_err.@"图片说明无#](结束字符串", s.@"Fn图片"());

    s.in = "!#[ab#[\n";
    s.index = 3;
    try expectError(progdoc_err.@"图片说明中含有#[或#]字符串", s.@"Fn图片"());

    s.in = "!#[ab#](http:(dd.com)\n";
    s.index = 3;
    try expectError(progdoc_err.@"图片链接中含有(字符", s.@"Fn图片"());

    s.in = "!#[ab#](http://dd.com\n";
    s.index = 3;
    try expectError(progdoc_err.@"图片链接无)结束字符", s.@"Fn图片"());

    s.in = "this is !#[progdoc pic#](https://pic.com). \r\n";
    s.index = 11;
    s.out.items.len = 0;
    try s.@"Fn图片"();
    try expectEqualSlices(u8, s.out.items, "<img src=\"https://pic.com\" alt=\"progdoc pic\" />");

    s.in = "this is !#[progdoc `[]` #](https://pic.com). \r\n";
    s.index = 11;
    s.out.items.len = 0;
    try s.@"Fn图片"();
    try expectEqualSlices(u8, s.out.items, "<img src=\"https://pic.com\" alt=\"progdoc <code>[]</code> \" />");
    s.@"Fn清空状态机"();
}

test "Fn格式正文C" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "the `a[i]=5;` #|she [[1. while]] #|he #[home#](http://com)\r\n");
    try s.@"Fn格式正文C"(false);
    try expectEqualSlices(u8, s.out.items, "the <code>a[i]=5;</code> #|she <a href=\"#N1. while\">1. while</a> #|he <a href=\"http://com\">home</a>");

    s.index = 0;
    s.out.items.len = 0;
    try s.@"Fn格式正文C"(true);
    try expectEqualSlices(u8, s.out.items, "the <code>a[i]=5;</code> ");
    try expect(s.index == 14);

    s.in = "#`<!#[pic#](http://.com) ``if(a<5) then{} \r\n";
    s.index = 0;
    s.out.items.len = 0;
    try s.@"Fn格式正文C"(false);
    try expectEqualSlices(u8, s.out.items, "`&lt;<img src=\"http://.com\" alt=\"pic\" /> <code>if(a&lt;5) then{} </code>");

    s.in = "test `#|` #|test\r\n";
    s.index = 0;
    s.out.items.len = 0;
    try s.@"Fn格式正文C"(false);
    try expectEqualSlices(u8, s.out.items, "test <code>#|</code> #|test");

    s.index = 0;
    s.out.items.len = 0;
    try s.@"Fn格式正文C"(true);
    try expectEqualSlices(u8, s.out.items, "test <code>#|</code> ");
    s.@"Fn清空状态机"();
}

test "Fn格式正文行" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#` `#[` test\r\nabc");
    try s.@"Fn格式正文行"();
    try expectEqualSlices(u8, s.out.items, "<p>` <code>#[</code> test</p>\r\n");
    s.@"Fn清空状态机"();
}

test "Fn标题行" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "1.1.2. test\r\nthis is ...");
    s.@"Fn判断当前行类别"();
    try s.@"Fn标题行"();
    try expectEqualSlices(u8, s.out.items, "<h3 id=\"N1.1.2. test\"><a href=\"#toc-1.1.2. test\">1.1.2. test</a></h3>\r\n");
    try expectEqualSlices(u8, s.@"目录".items, "<ul>\r\n<li><a id=\"toc-1.1.2. test\" href=\"#N1.1.2. test\">&nbsp;&nbsp;&nbsp;&nbsp;1.1.2. test</a></li>");
    s.@"Fn清空状态机"();
}

//找到ch返回true，post值是找到的字符。
//找不到ch返回false，post的值是行尾或字符串尾
//主要用于多行代码行S的文件名解析。
pub fn @"Fn当前行查找字符"(str: []const u8, start: usize, ch: u8, post: *usize) bool {
    var i = start;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\n' or str[i] == '\r') {
            post.* = i;
            return false;
        }
        if (str[i] == ch) {
            post.* = i;
            return true;
        }
    }
    post.* = i;
    return false;
}

test "Fn当前行查找字符" {
    var i: usize = undefined;
    try expect(@"Fn当前行查找字符"("abc.de\r\nfg", 1, '.', &i));
    try expect(i == 3);
    try expect(!@"Fn当前行查找字符"("abc.de\r\nfg", 4, '.', &i));
    try expect(i == 6);
    try expect(!@"Fn当前行查找字符"("abc.def", 4, '.', &i));
    try expect(i == 7);
    try expect(!@"Fn当前行查找字符"("abcde", 0, '.', &i));
    try expect(i == 5);
}

// 找到不是ch字符返回true，post值是从start处开始第1个不是ch的字符。
// 一直是ch字符返回false，post的值是行尾或字符串尾
// 主要用于多行代码行S的文件名解析。
fn @"Fn当前行查找不是ch的字符"(str: []const u8, start: usize, ch: u8, post: *usize) bool {
    var i = start;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\n' or str[i] == '\r') {
            post.* = i;
            return false;
        }
        if (str[i] != ch) {
            post.* = i;
            return true;
        }
    }
    post.* = i;
    return false;
}

test "Fn当前行查找不是ch的字符" {
    var i: usize = undefined;
    try expect(@"Fn当前行查找不是ch的字符"("```   abc.doc", 0, ' ', &i));
    try expect(i == 0);
    try expect(@"Fn当前行查找不是ch的字符"("```   abc.doc", 3, ' ', &i));
    try expect(i == 6);
    try expect(!@"Fn当前行查找不是ch的字符"("``   ", 3, ' ', &i));
    try expect(i == 5);
    try expect(!@"Fn当前行查找不是ch的字符"("  \r\nab", 0, ' ', &i));
    try expect(i == 2);
}

test "Fn多行代码行S" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "```");
    s.@"Fn判断当前行类别"();
    try s.@"Fn多行代码行S"();
    try expectEqualSlices(u8, s.out.items, "<figure>\r\n\t<figcaption class=\"-cap\">\r\n\t\t<cite class=\"\"></cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index == 3);

    s.in = "``` test.zig ";
    s.out.items.len = 0;
    s.index = 0;
    s.@"Fn判断当前行类别"();
    try s.@"Fn多行代码行S"();
    try expectEqualSlices(u8, s.out.items, "<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index == 13);

    s.in = "``` test.zig\r\n";
    s.out.items.len = 0;
    s.index = 0;
    s.@"Fn判断当前行类别"();
    try s.@"Fn多行代码行S"();
    try expectEqualSlices(u8, s.out.items, "<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index == 12);

    s.in = "```test.zig\r\n";
    s.out.items.len = 0;
    s.index = 0;
    s.@"Fn判断当前行类别"();
    try s.@"Fn多行代码行S"();
    try expectEqualSlices(u8, s.out.items, "<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index == 11);

    s.in = "```shell\r\n";
    s.out.items.len = 0;
    s.index = 0;
    s.@"Fn判断当前行类别"();
    try s.@"Fn多行代码行S"();
    try expectEqualSlices(u8, s.out.items, "<figure>\r\n\t<figcaption class=\"shell-cap\">\r\n\t\t<cite class=\"shell\">shell</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index == 8);
    s.@"Fn清空状态机"();
}

test "Fn多行代码行C" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();

    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "print(\"#`[]\");  \r\n");
    try s.@"Fn多行代码行C"();
    try expectEqualSlices(u8, s.out.items, "<span class=\"line\">print(\"#`[]\");  </span>\r\n");
    try expect(s.index == 16);

    s.in = "  #[ #] #--";
    s.index = 0;
    s.out.items.len = 0;
    try s.@"Fn多行代码行C"();
    try expectEqualSlices(u8, s.out.items, "<span class=\"line\">  #[ #] #--</span>\r\n");
    try expect(s.index == 11);
    s.@"Fn清空状态机"();
}

test "parseline inner html" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#<<  \n<a>test `#[[</a>\n#>>aa\nbbb\n#>>>");
    try s.parseline();
    try expect(s.@"当前行类别" == .@"内嵌html多行S");
    try expect(s.@"上一行状态" == .@"内嵌html多行C");
    try s.parseline();
    try expectEqualSlices(u8, s.out.items, "<a>test `#[[</a>");
    try s.parseline();
    try expect(s.@"当前行类别" == .@"内嵌html多行E");
    try s.parseline();
    try expectEqualSlices(u8, s.out.items, "<a>test `#[[</a><p>bbb</p>\r\n");
    try expectError(progdoc_err.@"内嵌html结束行没有对应的开始行", s.parseline());
    s.@"Fn清空状态机"();
}

test "parseline 多行代码1" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "ab\r``` test.zig\r\nprint;\nmain() void\r\n```\n1.1. toc");
    try s.parseline();
    try expect(s.@"当前行开始索引" == 3);
    try expect(s.out.items.len == 11);

    try s.parseline();
    try expect(s.@"当前行开始索引" == 17);
    try expect(s.out.items.len == 119);

    try s.parseline();
    try expect(s.@"当前行开始索引" == 24);
    try expect(s.out.items.len == 153);

    try s.parseline();
    try expect(s.@"当前行开始索引" == 37);
    try expect(s.out.items.len == 192);

    try s.parseline();
    try expect(s.@"当前行开始索引" == 41);
    try expect(s.out.items.len == 216);
    try expect(!s.@"is输入尾部");

    try s.parseline();
    try expect(s.@"当前行开始索引" == 49);
    try expect(s.out.items.len == 278);
    try expect(s.@"is输入尾部");
    s.@"Fn清空状态机"();
}

test "parseline 多行代码2" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "```\r\nprint;\n``` test.zig\r\n");
    try s.parseline();
    try s.parseline();
    try expectError(progdoc_err.@"当前行是多行代码行S但上一行状态是多行代码行C", s.parseline());
    s.@"Fn清空状态机"();
}

test "列表栈" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var state = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "");
    var s = state.@"文档列表栈";
    try expect(s.top == -1);
    try expectError(progdoc_err.@"get时列表栈空", s.get());
    try expectError(progdoc_err.@"pop时列表栈空", s.pop());
    try expect(s.isempty());

    try s.push(.@"多行列表行1", .@"单行列表行C");
    try expect(s.top == 0);
    var x = try s.get();
    try expect(x.@"上一行列表类别" == .@"多行列表行1");
    try expect(x.@"上一行列表状态" == .@"单行列表行C");
    try s.set(.@"多行列表行正文项");
    x = try s.get();
    try expect(x.@"上一行列表状态" == .@"多行列表行正文项");

    s.top = 6;
    try expectError(progdoc_err.@"push时列表栈满", s.push(.@"多行列表行1", .@"单行列表行C"));
    state.@"Fn清空状态机"();
}

test "Fn列表S" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#- test`#-`");
    s.@"Fn判断当前行类别"();
    try s.@"Fn列表S"();
    try expectEqualSlices(u8, s.out.items, "<ul>\r\n<li> test<code>#-</code></li>\r\n");

    s.in = "#-- test [[aa]]\r\naa";
    s.@"当前行开始索引" = 0;
    s.out.items.len = 0;
    s.@"文档列表栈".empty();
    s.@"Fn判断当前行类别"();
    try s.@"Fn列表S"();
    try expectEqualSlices(u8, s.out.items, "<ul>\r\n<li><span> test <a href=\"#Naa\">aa</a></span>\r\n");
    s.@"Fn清空状态机"();
}

test "parseline 单行列表" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "a\n#- aaa\n #- bbb\n  \t #- ccc\n d");
    try s.parseline();
    try expectEqualSlices(u8, s.out.items, "<p>a</p>\r\n");
    try s.parseline();
    try expectEqualSlices(u8, s.out.items, "<p>a</p>\r\n<ul>\r\n<li> aaa</li>\r\n");
    try s.parseline();
    try s.parseline();
    try s.parseline();
    try expectEqualSlices(u8, s.out.items, "<p>a</p>\r\n<ul>\r\n<li> aaa</li>\r\n<li> bbb</li>\r\n<li> ccc</li>\r\n</ul>\r\n<p> d</p>\r\n");
    s.@"Fn清空状态机"();
}

test "parseline 多行列表" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#--a\na1\na2\n#-b\n#-b1\na3\n#-c1\na4\n#--");
    while (s.@"当前行开始索引" < s.in.len) {
        try s.parseline();
    }
    try expectEqualSlices(u8, s.out.items, "<ul>\r\n<li><span>a</span>\r\n<br /><span>a1</span>\r\n<br /><span>a2</span>\r\n<ul>\r\n<li>b</li>\r\n<li>b1</li>\r\n</ul>\r\n<span>a3</span>\r\n<ul>\r\n<li>c1</li>\r\n</ul>\r\n<span>a4</span>\r\n</li>\r\n</ul>\r\n");
    s.@"Fn清空状态机"();

    var s1 = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#--a\n#--b\nb1\n#-bb1\n#-bb2\n#--\n#--");
    while (s1.@"当前行开始索引" < s1.in.len) {
        try s1.parseline();
    }
    try expectEqualSlices(u8, s1.out.items, "<ul>\r\n<li><span>a</span>\r\n<ul>\r\n<li><span>b</span>\r\n<br /><span>b1</span>\r\n<ul>\r\n<li>bb1</li>\r\n<li>bb2</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n");
    s1.@"Fn清空状态机"();
}

test "parseline 列表错误" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#--a\na1\n``` test.zig\n");
    try s.parseline();
    try s.parseline();
    try expectError(progdoc_err.@"多行列表行没有对应的结束行", s.parseline());
    s.@"Fn清空状态机"();

    var s1 = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "a\n#--");
    try s1.parseline();
    try expectError(progdoc_err.@"多行列表行结束行没有对应的开始行", s1.parseline());
    s1.@"Fn清空状态机"();
}

test "Fn判断表格单元格类别" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#|   #|  #| #- \n");
    s.index = 2;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 2);
    try expect(s.@"当前表格单元格类别" == .@"格式正文行");

    s.index = 7;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 7);
    try expect(s.@"当前表格单元格类别" == .@"格式正文行");

    s.in = "#|#--#|#- a#|  #-b #|  #--\n#|   #-- cc #|#--";
    s.index = 2;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 5);
    try expect(s.@"当前表格单元格类别" == .@"多行列表行E");

    s.index = 7;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 9);
    try expect(s.@"当前表格单元格类别" == .@"单行列表行");

    s.index = 13;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 17);
    try expect(s.@"当前表格单元格类别" == .@"单行列表行");

    s.index = 21;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 26);
    try expect(s.@"当前表格单元格类别" == .@"多行列表行E");

    s.index = 29;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 35);
    try expect(s.@"当前表格单元格类别" == .@"多行列表行S");

    s.index = 41;
    s.@"Fn判断表格单元格类别"();
    try expect(s.index == 44);
    try expect(s.@"当前表格单元格类别" == .@"多行列表行E");

    s.@"Fn清空状态机"();
}

test "Fn填写表格单元格内容" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#| ab#|");
    try s.@"表格单元格列表栈".append(.{});
    s.index = 2;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    try expectEqualSlices(u8, s.out.items, " ab");

    s.in = "#|#-- a1 #|a2 #| #- ab1 #| #- ab2 #| #-- ac1 #| #--#| #--";
    s.index = 2;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 11;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 16;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 26;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 36;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 47;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    s.index = 53;
    s.@"Fn判断表格单元格类别"();
    try s.@"Fn填写表格单元格内容"();
    try expectEqualSlices(u8, s.out.items, " ab<ul>\r\n<li><span> a1 </span>\r\n<br /><span>a2 </span>\r\n<ul>\r\n<li> ab1 </li>\r\n<li> ab2 </li>\r\n<li><span> ac1 </span>\r\n</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n");

    s.@"Fn清空状态机"();
}

test "Fn表格开始单行" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    //表格中不能用行代码
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#|<1.1.aa #|>#`#`#`bb #|^c[[c]] #| #-dd #|  #--ee\r\n");
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格开始单行"();
    try expect(s.@"表格总列数" == 5);
    try expect(s.@"表格单元格列表栈".items.len == 5);
    try expectEqualSlices(u8, s.out.items, "<tr>\r\n<td class=\"t_left\">1.1.aa </td>\r\n<td class=\"t_right\">```bb </td>\r\n<td class=\"t_center\">c<a href=\"#Nc\">c</a> </td>\r\n<td> #-dd </td>\r\n<td>  #--ee</td>\r\n</tr>\r\n");
    s.@"Fn清空状态机"();
}

test "Fn表格行单行C" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#|<a1#|b1#|c1\r\n#|a2#|b2#|c2\r\n#|a3#|b3#|c3\r\n");
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格开始单行"();
    try expect(s.@"表格总列数" == 3);
    s.@"当前行开始索引" = 15;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行单行C"();
    s.@"当前行开始索引" = 29;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行单行C"();
    try expectEqualSlices(u8, s.out.items, "<tr>\r\n<td class=\"t_left\">a1</td>\r\n<td>b1</td>\r\n<td>c1</td>\r\n</tr>\r\n<tr>\r\n<td>a2</td>\r\n<td>b2</td>\r\n<td>c2</td>\r\n</tr>\r\n<tr>\r\n<td>a3</td>\r\n<td>b3</td>\r\n<td>c3</td>\r\n</tr>\r\n");

    s.@"当前行开始索引" = 0;
    s.index = 0;
    s.in = "#| 12";
    s.@"Fn判断当前行类别"();
    try expectError(progdoc_err.@"与上一行表格列数不相等", s.@"Fn表格行单行C"());
    s.@"Fn清空状态机"();
}

test "Fn表格行多行" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#|<a1#|#--b1#|c1\r\n#|a2#|^b2#|#-c2\r\n#|a3#|#-b3#|#-c3\r\n#|#|#--#|#\r\n");
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格开始多行"();
    try expect(s.@"表格总列数" == 3);
    s.@"当前行开始索引" = s.index + 2;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行多行C"();
    s.@"当前行开始索引" = s.index + 2;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行多行C"();
    s.@"当前行开始索引" = s.index + 2;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行多行C"();
    try s.@"Fn表格行多行E"();
    try expectEqualSlices(u8, s.out.items, "<tr>\r\n<td class=\"t_left\">a1<br />a2<br />a3<br /></td>\r\n<td><ul>\r\n<li><span>b1</span>\r\n<br /><span>^b2</span>\r\n<ul>\r\n<li>b3</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n</td>\r\n<td>c1<br /><ul>\r\n<li>c2</li>\r\n<li>c3</li>\r\n</ul>\r\n#</td>\r\n</tr>\r\n");

    s.in = "#|aa#|bb#|cc";
    s.@"当前行开始索引" = 0;
    s.index = 0;
    s.out.items.len = 0;
    s.@"Fn判断当前行类别"();
    try s.@"Fn表格行多行S"();
    try expectEqualSlices(u8, s.out.items, "<tr>\r\n");
    try expectEqualSlices(u8, s.@"多行表格行缓冲".@"单元格".items[0].items, "<td>aa");
    try expectEqualSlices(u8, s.@"多行表格行缓冲".@"单元格".items[1].items, "<td>bb");
    try expectEqualSlices(u8, s.@"多行表格行缓冲".@"单元格".items[2].items, "<td>cc");

    s.@"Fn清空状态机"();
}

test "parseline 单行表格" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "ab\r#|#-a1 #|b1 #|c1 \n#|a2 #| b2#|^c2 \r#|a3 #|b3#| \r\n#- ll");
    while (!s.@"is输入尾部") {
        try s.parseline();
    }
    try expectEqualSlices(u8, s.out.items, "<p>ab</p>\r\n<table>\r\n<tr>\r\n<td>#-a1 </td>\r\n<td>b1 </td>\r\n<td>c1 </td>\r\n</tr>\r\n<tr>\r\n<td>a2 </td>\r\n<td> b2</td>\r\n<td class=\"t_center\">c2 </td>\r\n</tr>\r\n<tr>\r\n<td>a3 </td>\r\n<td>b3</td>\r\n<td> </td>\r\n</tr>\r\n</table>\r\n<ul>\r\n<li> ll</li>\r\n");
    s.@"Fn清空状态机"();
}

test "parseline 多行表格" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var al = arena.allocator();
    defer arena.deinit();
    var s = try @"Tprogdoc格式转换状态机".createStatusMachine(al, "#|---\n#|<#--a1#|b1\n#|>#-a2#|#--b2\n#|#-a3#|b3\n#|#--#|b4\n#| #|#--\n#|---\n#|a6#|b6\n#|---\n#|a7#|b7\n#|a8#|b8\n#|---\n#|a9#|b9\nb");
    while (!s.@"is输入尾部") {
        try s.parseline();
    }
    try expectEqualSlices(u8, s.out.items, "<table>\r\n<tr>\r\n<td class=\"t_left\"><ul>\r\n<li><span>a1</span>\r\n<br /><span>&gt;#-a2</span>\r\n<ul>\r\n<li>a3</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n<br /> </td>\r\n<td>b1<br /><ul>\r\n<li><span>b2</span>\r\n<br /><span>b3</span>\r\n<br /><span>b4</span>\r\n</li>\r\n</ul>\r\n</td>\r\n</tr>\r\n<tr>\r\n<td>a6</td>\r\n<td>b6</td>\r\n</tr>\r\n<tr>\r\n<td>a7<br />a8</td>\r\n<td>b7<br />b8</td>\r\n</tr>\r\n<tr>\r\n<td>a9</td>\r\n<td>b9</td>\r\n</tr>\r\n</table>\r\n<p>b</p>\r\n");
    s.@"Fn清空状态机"();
}
