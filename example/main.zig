const std = @import("std");
const progdoc = @import("progdoc");
pub fn main() !void {
    // 因人工编写的program doc的文本文件一般情况下不可能太大，所以设置最大输入文件长度为100M。
    const @"最大输入文件长度" = 0x10_0000 * 100; //100M
    // 使用gpa分配器，还可使用arena或其它分配器。
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const al = gpa.allocator();
    // var al = std.testing.allocator; // 用于test

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var al = arena.allocator();
    const args = try std.process.argsAlloc(al); //获取命令行参数，第0个是可执行程序本身
    if (args.len != 2) {
        std.debug.print("not input file, please input:\r\nprogdoc example.pd\r\n", .{});
        return;
    }

    // 获取不包含后缀的文件名
    var iend: usize = 0;
    _ = progdoc.@"Fn当前行查找字符"(args[1], 0, '.', &iend);
    const fname = args[1][0..iend];

    //打开输入文件名，并一次性读入到内存
    var home = std.fs.cwd();
    defer home.close();
    var infile = try home.openFile(args[1], .{});
    defer infile.close();
    const input = try infile.readToEndAlloc(al, @"最大输入文件长度");

    //解析生成html
    var s = try progdoc.@"Tprogdoc格式转换状态机".createStatusMachine(al, input);
    try s.parseProgdoc();

    //生成输出文件名
    var outfname = try std.ArrayList(u8).initCapacity(al, 80);
    defer outfname.deinit();
    try outfname.appendSlice(fname);
    try outfname.appendSlice(".html");

    //创建输出文件，并一次性写入解析结果
    var outfile = try home.createFile(outfname.items, .{});
    defer outfile.close();

    try outfile.writeAll(s.out.items);
    s.@"Fn清空状态机"();
}
