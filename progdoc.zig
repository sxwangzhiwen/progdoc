const std=@import("std");
const expect=std.testing.expect;
const expectEqualSlices=std.testing.expectEqualSlices;
const expectEqual=std.testing.expectEqual;
const expectError=std.testing.expectError;
const print=std.debug.print;
const assert=std.debug.assert;
const process=std.process;

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

const @"T当前行状态"=enum{
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
const @"T当前行类别"=enum{
    @"格式正文行",
    @"标题行",          // 1.1. AAA
    @"多行代码S",       // ``` AAA.zig
    @"多行代码SE",      // ```
    @"单行列表行",      // #- AAA
    @"多行列表行S",     // #-- AAA
    @"多行列表行E",     // #--
    @"多行表格行SE",    // #|-
    @"单行表格行",      // #| AAA
    @"内嵌html多行S",   // #<<
    @"内嵌html多行E",   // #>>
};

const @"T上一行状态"=enum{
    @"无后续影响",
    @"多行代码行C",
    @"列表C",
    @"表格C",
    @"内嵌html多行C",
};

const @"T当前表格单元格类别"=enum{
    @"格式正文行",
    @"单行列表行",
    @"多行列表行S",
    @"多行列表行E",
};

//多行表格行是指多行表示1个表格行。
const @"T上一行表格状态"=enum{
    @"单行表格行C",
    @"多行表格开始行", // 整个表格开始行，后面是多行表格行
    @"多行表格行开始行", // 在表格中的多行表格开始行
    @"多行表格行C",
};

const @"Tprogdoc格式转换状态机"=struct{
    in:[]const u8, // 读取缓冲区
    out:std.ArrayList(u8), // 多行表格行输出时，需要暂时变到多行输出缓冲
    @"行号":usize=1, // 主要用于出错信息显示
    @"当前行开始索引":usize=0,
    @"当前行类别":@"T当前行类别"=undefined,
    @"上一行状态":@"T上一行状态"=.@"无后续影响",
    index:usize=0, // 当前行解析的当前字符索引
    @"标题级数":u8=0,
    @"目录":std.ArrayList(u8), // 目录暂时缓冲区，文本处理完后插入到输出流的@"插入目录位置"
    @"插入目录位置":usize=0,
    @"当前行状态":@"T当前行状态"=.@"格式正文行",
    @"is输入尾部":bool=false, // 当 true 时表示读到文件尾部，需要结束处理。
    @"文档列表栈":@"T列表栈"=.{}, // 为了处理多级列表，引入多行列表行，需要用栈来实现。
    @"表格总列数":usize=0, // 处理表格时，单元格的总个数。
    @"表格当前列序号":usize=0,
    @"表格单元格列表栈":std.ArrayList(@"T列表栈"), // 处理多行表格行中的列表，以实现在表格单元格中写列表。
    @"当前表格单元格类别":@"T当前表格单元格类别"=undefined,
    @"上一行表格状态":@"T上一行表格状态"=undefined,
    @"多行表格行缓冲":@"T多行表格行缓冲", // 处理多行表格行时的暂时缓冲输出。
    @"多行表格temp":std.ArrayList(u8), // 处理多行表格行时的配套变量。
    @"内链外链图片temp":std.ArrayList(u8), //处理相应格式时的配套变量。
    //
};

// 使用gpa分配器，还可使用arena或其它分配器。检测出多行表格行缓冲和主程序的文件名动态数组有泄漏，但影响不大，不处理了。
//var gpa=std.heap.GeneralPurposeAllocator(.{}){};
//const al=gpa.allocator();
//var al=std.testing.allocator;
var arena=std.heap.ArenaAllocator.init(std.heap.page_allocator);
//defer arena.deinit();
const al=arena.allocator();

//输入的是待解析的文本。后续函数参数使用的均是指针，是为了在函数中能改变状态机的属性值。
fn @"Fn新建状态机"(inbuf:[]const u8) !@"Tprogdoc格式转换状态机"{
    var list=try std.ArrayList(u8).initCapacity(al,80);
    var list1=try std.ArrayList(u8).initCapacity(al,80);
    try list1.appendSlice("<ul>\r\n");
    var list2=try std.ArrayList(@"T列表栈").initCapacity(al,16);
    var list3=try std.ArrayList(u8).initCapacity(al,80);
    var list4=try std.ArrayList(u8).initCapacity(al,80);
    var b=try @"Fn新建多行表格行缓冲"();
    return .{.in=inbuf, .out=list, 
    .@"目录"=list1,
    .@"表格单元格列表栈"=list2,
    .@"多行表格行缓冲"=b,
    .@"多行表格temp"=list3,
    .@"内链外链图片temp"=list4,};
}

fn @"Fn清空状态机"(s:*@"Tprogdoc格式转换状态机") void{
    s.*.in=undefined;
    s.*.out.deinit();
    s.*.@"目录".deinit();
    s.*.@"表格单元格列表栈".deinit();
    s.*.@"多行表格temp".deinit();
    s.*.@"内链外链图片temp".deinit();
    @"Fn删除多行表格行缓冲"(&s.*.@"多行表格行缓冲");
    s.*.out=undefined;
}

const progdoc_err=error{
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

// 因表格总列数和表格单元格字符数根据实际输入来定，不能在编译期确定，所以设计了简陋的二维动态数组数据结构。
const @"T多行表格行缓冲"=struct {
    @"单元格":std.ArrayList(std.ArrayList(u8)),
    @"使用长度":usize=0,
    @"容量":usize=0,
    fn @"Fn获取多行表格行单元格缓冲"(self:@"T多行表格行缓冲",@"序号":usize) !std.ArrayList(u8){
        if(@"序号">=self.@"使用长度"){
            return progdoc_err.@"多行表格行缓冲溢出错误";
        }
        return self.@"单元格".items[@"序号"];
    }
    fn @"Fn多行表格行单元格缓冲追加字符串"(self:*@"T多行表格行缓冲",@"序号":usize,str:[]const u8) !void{
        if(@"序号">=self.@"使用长度"){
            return progdoc_err.@"多行表格行缓冲溢出错误";
        }
        try self.@"单元格".items[@"序号"].appendSlice(str);
    }
    fn @"Fn增加多行表格行单元格缓冲"(self:*@"T多行表格行缓冲") !void{
        if(self.@"使用长度">=self.@"容量"){
            var i=self.@"容量";
            self.@"容量"+=10;
            while(i<self.@"容量"):(i+=1){
                var j=try std.ArrayList(u8).initCapacity(al,80);
                try self.@"单元格".append(j);
            }
        }else{
            self.@"单元格".items[self.@"使用长度"].items.len=0;
        }
        self.@"使用长度"+=1;
    }
    fn @"Fn清空多行表格行单元格缓冲"(self:*@"T多行表格行缓冲") void{
        var i:usize=0;
        while(i<self.@"使用长度"):(i+=1){
            self.@"单元格".items[i].items.len=0;
        }
    }
    fn @"Fn多行表格行单元格缓冲全部追加字符串"(self:*@"T多行表格行缓冲",str:[]const u8) !void{
        var i:usize=0;
        while(i<self.@"使用长度"):(i+=1){
            try self.@"单元格".items[i].appendSlice(str);
        }
    }
};

fn @"Fn新建多行表格行缓冲"() !@"T多行表格行缓冲"{
    const c=try std.ArrayList(std.ArrayList(u8)).initCapacity(al,10);
    var r:@"T多行表格行缓冲"=.{.@"单元格"=c,.@"容量"=10};
    var i:usize=0;
    r.@"使用长度"=0;
    while(i<r.@"容量"):(i+=1){
        var j=try std.ArrayList(u8).initCapacity(al,80);
        try r.@"单元格".append(j);
    }
    return r;
}

fn @"Fn删除多行表格行缓冲"(r:*@"T多行表格行缓冲") void{
    //var i:usize=0;
    for(r.*.@"单元格".items) |*v|{
        v.*.deinit();
    }
    r.*.@"单元格".deinit();
    r.*.@"容量"=0;
    r.*.@"使用长度"=0;
    r.*.@"单元格"=undefined;
}

test "多行表格行缓冲" {
    var r=try @"Fn新建多行表格行缓冲"();
    var i:usize=0;
    while(i<13):(i+=1){
        try r.@"Fn增加多行表格行单元格缓冲"();
    }
    try expect(r.@"容量"==20);
    try expect(r.@"使用长度"==13);
    try expectError(progdoc_err.@"多行表格行缓冲溢出错误",r.@"Fn获取多行表格行单元格缓冲"(13));

    try r.@"Fn多行表格行单元格缓冲追加字符串"(0,"test");
    var x=try r.@"Fn获取多行表格行单元格缓冲"(0);
    try expectEqualSlices(u8,x.items,"test");

    try r.@"Fn多行表格行单元格缓冲追加字符串"(1,"test1");
    try r.@"Fn多行表格行单元格缓冲追加字符串"(1,"test2");
    x=try r.@"Fn获取多行表格行单元格缓冲"(1);
    try expectEqualSlices(u8,x.items,"test1test2");

    try r.@"Fn多行表格行单元格缓冲全部追加字符串"("<end>");
    x=try r.@"Fn获取多行表格行单元格缓冲"(0);
    try expectEqualSlices(u8,x.items,"test<end>");
    x=try r.@"Fn获取多行表格行单元格缓冲"(1);
    try expectEqualSlices(u8,x.items,"test1test2<end>");
    x=try r.@"Fn获取多行表格行单元格缓冲"(2);
    try expectEqualSlices(u8,x.items,"<end>");

    x=try r.@"Fn获取多行表格行单元格缓冲"(10);
    try x.append('a');
    try x.append('b');
    try expectEqualSlices(u8,x.items,"<end>ab");
    r.@"Fn清空多行表格行单元格缓冲"();
    try expect(r.@"容量"==20);
    @"Fn删除多行表格行缓冲"(&r);
}

// strs是编译期确定个数的字符串数组，从buf的第start个字符开始，按strs中的先后顺序，逐个和strs中的字符串比对。
// 如果找到任1个，start值增加找到字符串的长度。
// 找到第n个字符串，返回n；没找到，返回 -1。
// strs的顺序非常重要，调用时要考虑好了。如：
// .{"\r\n","\r","\n"} 可正确找出对应字符串，当有"\r\n"时，返回0。
// .{"\r","\r\n","\n"} 不能正确找出，当有"\r\n"时，返回0，而不是返回想要的1。
fn @"Fnis包含字符串"(buf:[]const u8,start:*usize,comptime strs:anytype) i8{
    inline for(strs) |str,i|{
        if(buf.len-start.*>=str.len){
            for(str) |v,j| {
                if(v!=buf[start.*+j]){
                    break;
                }
            }else{
                start.*+=str.len;
                return i;
            }
        }
    }
    return -1;
}

test "Fnis包含字符串" {
    var i:i8=undefined;
    var s:usize=0;
    i=@"Fnis包含字符串"("#| abc",&s,.{"#-","#--","#|","#|-"});
    try expect(i==2);
    try expect(s==2);

    s=3;
    i=@"Fnis包含字符串"("1\r\n#| abc",&s,.{"#-","#--","#|","#|-"});
    try expect(i==2);
    try expect(s==5);

    s=0;
    i=@"Fnis包含字符串"("#",&s,.{"#-","#--","#|","#|-"});
    try expect(i==-1);
    try expect(s==0);

    s=0;
    i=@"Fnis包含字符串"("#-",&s,.{"#-","#--","#|","#|-"});
    try expect(i==0);
    try expect(s==2);

    s=0;
    i=@"Fnis包含字符串"("``\r",&s,.{"```","``\r","``\n","``","`"});
    try expect(i==1);
    try expect(s==3);

    s=0;
    i=@"Fnis包含字符串"("",&s,.{"```","``\r","``\n","``","`"});
    try expect(i==-1);
    try expect(s==0);
}

fn @"Fn判断当前行类别"(ptr:*@"Tprogdoc格式转换状态机") void {
    var i=ptr.*.@"当前行开始索引";
    var j:i8=-1;
    switch(ptr.*.in[i]) {
        '`' => {
            j=@"Fnis包含字符串"(ptr.*.in,&i,.{"```\r","```\n","```",});
            switch(j) {
                0,1 => {
                    ptr.*.@"当前行类别"=.@"多行代码SE";
                    i-=1;
                },
                2 => {
                    if(i==ptr.*.in.len){
                        ptr.*.@"当前行类别"=.@"多行代码SE";
                    }else{
                        ptr.*.@"当前行类别"=.@"多行代码S";
                    }
                },
                else => {
                    ptr.*.@"当前行类别"=.@"格式正文行";
                },
            }
        },
        '0'...'9' => {
            var @"is标题":bool=false;
            var @"句点个数":u8=0;
            while(i<ptr.*.in.len):(i+=1){
                if(ptr.*.in[i]!='.' and (ptr.*.in[i]<'0' or ptr.*.in[i]>'9')){
                    break;
                }
                if(ptr.*.in[i]=='.'){
                    @"句点个数"+=1;
                    if(i==ptr.*.in.len-1){
                        @"is标题"=true;
                        break;
                    }
                    if(ptr.*.in[i+1]<'0' or ptr.*.in[i+1]>'9'){
                        @"is标题"=true;
                        break;
                    }
                }
            }
            if(@"is标题"){
                i+=1;
                ptr.*.@"当前行类别"=.@"标题行";
                ptr.*.@"标题级数"=@"句点个数";
            }else{
                i=ptr.*.@"当前行开始索引";
                ptr.*.@"当前行类别"=.@"格式正文行";
            }
        },
        ' ','\t','#' => {
            j=@"Fnis包含字符串"(ptr.*.in,&i,.{"#|-","#|","#<<","#>>"});
            switch(j){
                0 => {
                    ptr.*.@"当前行类别"=.@"多行表格行SE";
                },
                1 => {
                    ptr.*.@"当前行类别"=.@"单行表格行";
                },
                2 => {
                    ptr.*.@"当前行类别"=.@"内嵌html多行S";
                },
                3 => {
                    ptr.*.@"当前行类别"=.@"内嵌html多行E";
                },
                else => {
                    while(i<ptr.*.in.len):(i+=1){
                        if(ptr.*.in[i]!=' ' and ptr.*.in[i]!='\t'){
                            break;
                        }
                    }
                    j=@"Fnis包含字符串"(ptr.*.in,&i,.{"#--\r","#--\n","#--","#-"});
                    switch(j) {
                        0,1 => {
                            ptr.*.@"当前行类别"=.@"多行列表行E";
                            i-=1;
                        },
                        2 => {
                            if(i==ptr.*.in.len){
                                ptr.*.@"当前行类别"=.@"多行列表行E";
                            }else{
                                ptr.*.@"当前行类别"=.@"多行列表行S";
                            }
                        },
                        3 => {
                            ptr.*.@"当前行类别"=.@"单行列表行";
                        },
                        else => {
                            i=ptr.*.@"当前行开始索引";
                            ptr.*.@"当前行类别"=.@"格式正文行";
                        },
                    }
                },
            }
        },
        else => {
            ptr.*.@"当前行类别"=.@"格式正文行";
        }
    }
    ptr.*.index=i;
}

test "Fn判断当前行类别 内嵌html" {
    var s=try @"Fn新建状态机"("#>>");
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"内嵌html多行E");
    try expect(s.index==3);

    s.in="#<<";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"内嵌html多行S");
    try expect(s.index==3);

    @"Fn清空状态机"(&s);
}

test "Fn判断当前行类别 多行代码S 多行代码SE"{
    var s=try @"Fn新建状态机"("");
    s.in="`";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="```";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码SE");
    try expect(s.index==3);
    
    s.in="``";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="```\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码SE");
    try expect(s.index==3);

    s.in="```\r\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码SE");
    try expect(s.index==3);

    s.in="````";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码S");
    try expect(s.index==3);

    s.in="``` hello.zig";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码S");
    try expect(s.index==3);

    s.in="012345\r\n```\r\n``` test.zig\r\n";
    s.@"当前行开始索引"=8;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码SE");
    try expect(s.index==11);

    s.@"当前行开始索引"=13;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行代码S");
    try expect(s.index==16);
    @"Fn清空状态机"(&s);
}

test "Fn判断当前行类别 标题"{
    var s=try @"Fn新建状态机"("");
    s.in="1";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in=".";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="1.";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==1);
    try expect(s.index==2);

    s.in="1.\r\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==1);
    try expect(s.index==2);

    s.in=" 12.135..12";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="12.135..12";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==2);
    try expect(s.index==7);

    s.in="12.1.1.5. test";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==4);
    try expect(s.index==9);

    s.in="123456";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);


    s.in="0123\n1";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n.";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n1.\r\n";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==1);
    try expect(s.index==7);

    s.in="0123\n 12.135..12";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n12.135..12";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==2);
    try expect(s.index==12);

    s.in="0123\n12.1.1.5. test";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"标题行");
    try expect(s.@"标题级数"==4);
    try expect(s.index==14);

    s.in="0123\n123456";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);
    @"Fn清空状态机"(&s);
}

test "Fn判断当前行类别 表格行"{
    var s=try @"Fn新建状态机"("");
    s.in="#";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="#advbdafs";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in=" #|";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="#|";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行表格行");
    try expect(s.index==2);

    s.in="#|\r\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行表格行");
    try expect(s.index==2);

    s.in="#| adfsad ";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行表格行");
    try expect(s.index==2);

    s.in="#|-";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行表格行SE");
    try expect(s.index==3);

    s.in="#|----dd#|---";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行表格行SE");
    try expect(s.index==3);


    s.in="0123\n#";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n#advbdafs";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n #|";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n#|\r\n";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行表格行");
    try expect(s.index==7);

    s.in="0123\n#| adfsad ";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行表格行");
    try expect(s.index==7);

    s.in="0123\n#|-";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行表格行SE");
    try expect(s.index==8);

    s.in="0123\n#|----dd#|---";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行表格行SE");
    try expect(s.index==8);
    @"Fn清空状态机"(&s);
}

test "Fn判断当前行类别 列表行"{
    var s=try @"Fn新建状态机"("");
    s.in="#-";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==2);

    s.in="   abc\r\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="#-\r\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==2);

    s.in="#- ";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==2);

    s.in="#- aadf\n";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==2);

    s.in="# -";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==0);

    s.in="  \t  \t\t #- adfsaf";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==10);

    s.in="#--";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==3);

    s.in="#--\r\n adfaf";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==3);

    s.in="  \t#--\r\n adfaf";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==6);

    s.in="#-- adfaf";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行S");
    try expect(s.index==3);

    s.in="  #-- adfaf";
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行S");
    try expect(s.index==5);


    s.in="0123\n#-\r\n";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==7);

    s.in="0123\n#- ";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==7);

    s.in="0123\n#- aadf\n";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==7);

    s.in="0123\n# -";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"格式正文行");
    try expect(s.index==5);

    s.in="0123\n  \t  \t\t #- adfsaf";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"单行列表行");
    try expect(s.index==15);

    s.in="0123\n#--";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==8);

    s.in="0123\n#--\r\n adfaf";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==8);

    s.in="0123\n  \t#--\r\n adfaf";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行E");
    try expect(s.index==11);

    s.in="0123\n#-- adfaf";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行S");
    try expect(s.index==8);

    s.in="0123\n  #-- adfaf";
    s.@"当前行开始索引"=5;
    @"Fn判断当前行类别"(&s);
    try expect(s.@"当前行类别"==.@"多行列表行S");
    try expect(s.index==10);
    @"Fn清空状态机"(&s);
}

// 仅对< > 进行实体替换，其它字符原样输出。用于多行代码行。
fn @"Fn无格式正文字符"(ptr:*@"Tprogdoc格式转换状态机") !void{
    switch(ptr.*.in[ptr.*.index]){
        '<' => {
            try ptr.*.out.appendSlice("&lt;");
        },
        '>' => {
            try ptr.*.out.appendSlice("&gt;");
        },
        else => |v|{
            try ptr.*.out.append(v);
        },
    }
    ptr.*.index+=1;
}

test "Fn无格式正文字符" {
    var s=try @"Fn新建状态机"("a<b>c#`d\n");
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a");
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a&lt;");
    
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a&lt;b");
    
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a&lt;b&gt;");
    
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a&lt;b&gt;c");

    try @"Fn无格式正文字符"(&s);
    try @"Fn无格式正文字符"(&s);
    try @"Fn无格式正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"a&lt;b&gt;c#`d");
    @"Fn清空状态机"(&s);
}

// < > 实体替换，#` 替换为 ` ，用于普通正文字符输出。
fn @"Fn普通正文字符"(ptr:*@"Tprogdoc格式转换状态机") !void{
    switch(ptr.*.in[ptr.*.index]){
        '<' => {
            try ptr.*.out.appendSlice("&lt;");
        },
        '>' => {
            try ptr.*.out.appendSlice("&gt;");
        },
        '#' => {
            const j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#`"});
            if(j==0){
                try ptr.*.out.append('`');
                ptr.*.index-=1;
            }else{
                try ptr.*.out.append('#');
            }
        },
        else => |v|{
            try ptr.*.out.append(v);
        },
    }
    ptr.*.index+=1;
}

test "Fn普通正文字符" {
    var s=try @"Fn新建状态机"("t<>#`#e");
    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"t");
    try expect(s.index==1);

    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"t&lt;");
    try expect(s.index==2);

    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"t&lt;&gt;");
    try expect(s.index==3);

    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"t&lt;&gt;`");
    try expect(s.index==5);

    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"t&lt;&gt;`#");
    try expect(s.index==6);

    s.in="#`";
    s.out.items.len=0;
    s.index=0;
    try @"Fn普通正文字符"(&s);
    try expectEqualSlices(u8,s.out.items,"`");
    try expect(s.index==2);
    @"Fn清空状态机"(&s);
}

// BB`` AAA\r\n
// <code>AAA</code>
//从``后到行尾的所有字符原样输出，仅 < > 字符实体替换和 #` 替换为 `
//在表格中或正文中间慎重使用，容易出错。
fn @"Fn行代码"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<code>");
    while(ptr.*.index<ptr.*.in.len){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            try ptr.*.out.appendSlice("</code>");
            return;
        }
        try @"Fn普通正文字符"(ptr);
    }
    try ptr.*.out.appendSlice("</code>");
}

test "Fn行代码" {
    var s=try @"Fn新建状态机"("this ``");
    s.index=7;
    try @"Fn行代码"(&s);
    try expectEqualSlices(u8,s.out.items,"<code></code>");
    try expect(s.index==7);

    s.in="`` t<h#` #|";
    s.index=2;
    s.out.items.len=0;
    try @"Fn行代码"(&s);
    try expectEqualSlices(u8,s.out.items,"<code> t&lt;h` #|</code>");
    try expect(s.index==11);

    s.in="``test#[#]\r\nthis is";
    s.index=2;
    s.out.items.len=0;
    try @"Fn行代码"(&s);
    try expectEqualSlices(u8,s.out.items,"<code>test#[#]</code>");
    try expect(s.index==10);
    @"Fn清空状态机"(&s);
}

// `AAA`
// <code>AAA</code>
// 主要用于正常输出 [[ 等格式控制用的字符（类似于 \ 逃逸字符，或者用于程序短代码。
fn @"Fn短代码"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<code>");
    while(ptr.*.index<ptr.*.in.len){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            return progdoc_err.@"短代码无结束`字符";
        }
        if(ptr.*.in[ptr.*.index]=='`'){
            try ptr.*.out.appendSlice("</code>");
            ptr.*.index+=1;
            return;
        }
        try @"Fn普通正文字符"(ptr);
    }
    return progdoc_err.@"短代码无结束`字符";
}

test "Fn短代码" {
    var s=try @"Fn新建状态机"("");
    try expectError(progdoc_err.@"短代码无结束`字符",@"Fn短代码"(&s));

    s.in="test\na`";
    try expectError(progdoc_err.@"短代码无结束`字符",@"Fn短代码"(&s));

    s.in="test";
    try expectError(progdoc_err.@"短代码无结束`字符",@"Fn短代码"(&s));

    s.in="a`test<#`>b`ccc\r\n";
    s.index=2;
    s.out.items.len=0;
    try @"Fn短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"<code>test&lt;`&gt;b</code>");
    try expect(s.index==12);
    @"Fn清空状态机"(&s);
}

// AA`BB`CC
// AA<code>BB</code>
// 该函数主要用于内链、外链说明等处。
fn @"Fn普通正文字符和短代码"(ptr:*@"Tprogdoc格式转换状态机") !void{
    if(ptr.in[ptr.*.index]=='`'){
        const j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"`\n","`\r","``"});
        if(j>0 or ptr.*.index==ptr.*.in.len-1){
            return progdoc_err.@"短代码无结束`字符";
        }
        ptr.*.index+=1;
        try @"Fn短代码"(ptr);
    }else{
        try @"Fn普通正文字符"(ptr);
    }
}

test "Fn普通正文字符和短代码" {
    var s=try @"Fn新建状态机"("a`\r\n``b<`te`b#`c");
    s.index=1;
    try expectError(progdoc_err.@"短代码无结束`字符",@"Fn普通正文字符和短代码"(&s));

    s.index=4;
    try expectError(progdoc_err.@"短代码无结束`字符",@"Fn普通正文字符和短代码"(&s));

    s.index=6;
    s.out.items.len=0;
    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b");
    try expect(s.index==7);

    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b&lt;");

    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b&lt;<code>te</code>");
    try expect(s.index==12);

    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b&lt;<code>te</code>b");

    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b&lt;<code>te</code>b`");

    try @"Fn普通正文字符和短代码"(&s);
    try expectEqualSlices(u8,s.out.items,"b&lt;<code>te</code>b`c");
    @"Fn清空状态机"(&s);
}

// [[AAA]]
// <a href="#NAAA">AAA</a>
// 为了和标题锚点对应上，内链在链接处加 N 字符。因为数字开头的内链html不能正确处理。
// 没有锚点设置功能，建议写文档时分章节尽量短，内链只对应标题。
//内链中不能有 [[ ]] 字符串，分影响正确解析。
fn @"Fn内链"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<a href=\"#");
    try ptr.*.out.append('N');
    const istart=ptr.*.out.items.len;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]){
            '\n', '\r', '[', ']' => {
                var j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"\n","\r","[[","]]"});
                switch(j) {
                    0, 1 => {
                        return progdoc_err.@"内链无结束]]字符串";
                    },
                    2 => {
                        return progdoc_err.@"内链中含有[[字符串";
                    },
                    3 => {
                        const iend=ptr.*.out.items.len;
                        ptr.*.@"内链外链图片temp".items.len=0;
                        try ptr.*.@"内链外链图片temp".appendSlice(ptr.*.out.items[istart..iend]);
                        try ptr.*.out.appendSlice("\">");
                        try ptr.*.out.appendSlice(ptr.*.@"内链外链图片temp".items);
                        try ptr.*.out.appendSlice("</a>");
                        return;
                    },
                    else => {
                        try @"Fn普通正文字符和短代码"(ptr);
                    }
                }
            },
            else => {
                try @"Fn普通正文字符和短代码"(ptr);
            }
        }
    }
    return progdoc_err.@"内链无结束]]字符串";
}

test "Fn内链" {
    var s=try @"Fn新建状态机"("[[a");
    s.index=2;
    try expectError(progdoc_err.@"内链无结束]]字符串",@"Fn内链"(&s));

    s.in="[[a\n";
    s.index=2;
    try expectError(progdoc_err.@"内链无结束]]字符串",@"Fn内链"(&s));

    s.in="[[ab[[cd]]\n";
    s.index=2;
    try expectError(progdoc_err.@"内链中含有[[字符串",@"Fn内链"(&s));

    s.in="[[1.1. abcd]]ee";
    s.index=2;
    s.out.items.len=0;
    try @"Fn内链"(&s);
    try expectEqualSlices(u8,s.out.items,"<a href=\"#N1.1. abcd\">1.1. abcd</a>");
    try expect(s.index==13);

    s.in="[[1.1. `[[`a[bc]d]]ee";
    s.index=2;
    s.out.items.len=0;
    try @"Fn内链"(&s);
    try expectEqualSlices(u8,s.out.items,"<a href=\"#N1.1. <code>[[</code>a[bc]d\">1.1. <code>[[</code>a[bc]d</a>");
    try expect(s.index==19);
    @"Fn清空状态机"(&s);
}

// #[AAA#](BBB)
// <a href="BBB">AAA</a>
// 外链说明中，不能有 #[ #] 字符串，外链链接中，不能有 ( ) 字符，否则影响正常解析。
// 外链链接中，不建议有< > #` 字符，因为会实体替换。
fn @"Fn外链"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<a href=\"");
    const ipost=ptr.*.out.items.len;
    var isok:bool=false;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]){
            '\n', '\r' => {
                return progdoc_err.@"外链说明无#](结束字符串";
            },
            '#' =>{
                var j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#](","#[","#]"});
                switch(j) {
                    0 => {
                        isok=true;
                        break;
                    },
                    1,2 => {
                        return progdoc_err.@"外链说明中含有#[或#]字符串";
                    },
                    else => {
                        try @"Fn普通正文字符和短代码"(ptr);
                    }
                }
            },
            else => {
                try @"Fn普通正文字符和短代码"(ptr);
            },
        }
    }
    if(!isok){
        return progdoc_err.@"外链说明无#](结束字符串";
    }
    isok=false;
    const istart=ptr.*.out.items.len;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]){
            '(' => {
                return progdoc_err.@"外链链接中含有(字符";
            },
            '\n', '\r' => {
                return progdoc_err.@"外链链接无)结束字符";
            },
            ')' => {
                isok=true;
                ptr.*.index+=1;
                break;
            },
            else => {
                try @"Fn普通正文字符"(ptr);
            },
        }
    }
    if(!isok){
        return progdoc_err.@"外链链接无)结束字符";
    }
    try ptr.*.out.appendSlice("\">");
    const iend=ptr.*.out.items.len;
    ptr.*.@"内链外链图片temp".items.len=0;
    try ptr.*.@"内链外链图片temp".appendSlice(ptr.*.out.items[istart..iend]);
    try ptr.*.out.insertSlice(ipost,ptr.*.@"内链外链图片temp".items);
    ptr.*.out.items.len=iend;
    try ptr.*.out.appendSlice("</a>");
}

test "Fn外链" {
    var s=try @"Fn新建状态机"("#[ab");
    s.index=2;
    try expectError(progdoc_err.@"外链说明无#](结束字符串",@"Fn外链"(&s));

    s.in="#[ab\n";
    s.index=2;
    try expectError(progdoc_err.@"外链说明无#](结束字符串",@"Fn外链"(&s));

    s.in="#[ab#[\n";
    s.index=2;
    try expectError(progdoc_err.@"外链说明中含有#[或#]字符串",@"Fn外链"(&s));

    s.in="#[ab#](http:(dd.com)\n";
    s.index=2;
    try expectError(progdoc_err.@"外链链接中含有(字符",@"Fn外链"(&s));

    s.in="#[ab#](http://dd.com\n";
    s.index=2;
    try expectError(progdoc_err.@"外链链接无)结束字符",@"Fn外链"(&s));

    s.in="this is #[progdoc homepage#](https://progdoc.com). \r\n";
    s.index=10;
    s.out.items.len=0;
    try @"Fn外链"(&s);
    try expectEqualSlices(u8,s.out.items,"<a href=\"https://progdoc.com\">progdoc homepage</a>");

    s.in="this is #[progdoc `[]` #](https://progdoc.com). \r\n";
    s.index=10;
    s.out.items.len=0;
    try @"Fn外链"(&s);
    try expectEqualSlices(u8,s.out.items,"<a href=\"https://progdoc.com\">progdoc <code>[]</code> </a>");
    @"Fn清空状态机"(&s);
}

// !#[AAA#](BBB)
// <img src="BBB" alt="AAA" />
// 图片处理，和外链类似。
fn @"Fn图片"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<img src=\"");
    const ipost=ptr.*.out.items.len;
    var isok:bool=false;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]){
            '\n', '\r' => {
                return progdoc_err.@"图片说明无#](结束字符串";
            },
            '#' =>{
                var j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#](","#[","#]"});
                switch(j) {
                    0 => {
                        isok=true;
                        break;
                    },
                    1,2 => {
                        return progdoc_err.@"图片说明中含有#[或#]字符串";
                    },
                    else => {
                        try @"Fn普通正文字符和短代码"(ptr);
                    }
                }
            },
            else => {
                try @"Fn普通正文字符和短代码"(ptr);
            },
        }
    }
    if(!isok){
        return progdoc_err.@"图片说明无#](结束字符串";
    }
    isok=false;
    const istart=ptr.*.out.items.len;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]){
            '(' => {
                return progdoc_err.@"图片链接中含有(字符";
            },
            '\n', '\r' => {
                return progdoc_err.@"图片链接无)结束字符";
            },
            ')' => {
                isok=true;
                ptr.*.index+=1;
                break;
            },
            else => {
                try @"Fn普通正文字符"(ptr);
            },
        }
    }
    if(!isok){
        return progdoc_err.@"图片链接无)结束字符";
    }
    try ptr.*.out.appendSlice("\" alt=\"");
    const iend=ptr.*.out.items.len;
    ptr.*.@"内链外链图片temp".items.len=0;
    try ptr.*.@"内链外链图片temp".appendSlice(ptr.*.out.items[istart..iend]);
    try ptr.*.out.insertSlice(ipost,ptr.*.@"内链外链图片temp".items);
    ptr.*.out.items.len=iend;
    try ptr.*.out.appendSlice("\" />");
}

test "Fn图片" {
    var s=try @"Fn新建状态机"("!#[ab");
    s.index=3;
    try expectError(progdoc_err.@"图片说明无#](结束字符串",@"Fn图片"(&s));

    s.in="!#[ab\n";
    s.index=3;
    try expectError(progdoc_err.@"图片说明无#](结束字符串",@"Fn图片"(&s));

    s.in="!#[ab#[\n";
    s.index=3;
    try expectError(progdoc_err.@"图片说明中含有#[或#]字符串",@"Fn图片"(&s));

    s.in="!#[ab#](http:(dd.com)\n";
    s.index=3;
    try expectError(progdoc_err.@"图片链接中含有(字符",@"Fn图片"(&s));

    s.in="!#[ab#](http://dd.com\n";
    s.index=3;
    try expectError(progdoc_err.@"图片链接无)结束字符",@"Fn图片"(&s));

    s.in="this is !#[progdoc pic#](https://pic.com). \r\n";
    s.index=11;
    s.out.items.len=0;
    try @"Fn图片"(&s);
    try expectEqualSlices(u8,s.out.items,"<img src=\"https://pic.com\" alt=\"progdoc pic\" />");

    s.in="this is !#[progdoc `[]` #](https://pic.com). \r\n";
    s.index=11;
    s.out.items.len=0;
    try @"Fn图片"(&s);
    try expectEqualSlices(u8,s.out.items,"<img src=\"https://pic.com\" alt=\"progdoc <code>[]</code> \" />");
    @"Fn清空状态机"(&s);
}

// 处理普通正文，可以包括：短代码、行代码、内链、外链、图片、其它字符。
// istable为假时，表示当前行非表格行，一直处理到行尾或输入尾；
// istable为真时，表示当前行是表格行，处理到 #| 表格分界符或行尾或输入尾。
fn @"Fn格式正文C"(ptr:*@"Tprogdoc格式转换状态机",comptime istable:bool) !void{
    var i:i8=-1;
    while(ptr.*.index<ptr.*.in.len){
        switch(ptr.*.in[ptr.*.index]) {
            '`' => {
                i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"``"});
                if(i==0){
                    try @"Fn行代码"(ptr);
                }else{
                    ptr.*.index+=1;
                    try @"Fn短代码"(ptr);
                }
            },
            '[' => {
                i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"[["});
                if(i==0){
                    try @"Fn内链"(ptr);
                }else{
                    try ptr.*.out.append('[');
                    ptr.*.index+=1;
                }
            },
            '!' => {
                i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"!#["});
                if(i==0){
                    try @"Fn图片"(ptr);
                }else{
                    try ptr.*.out.append('!');
                    ptr.*.index+=1;
                }
            },
            '#' => {
                i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#[","#|"});
                switch(i) {
                    0 => {
                        try @"Fn外链"(ptr);
                    },
                    1 => {
                        if(istable) {
                            ptr.*.index-=2;
                            return;
                        }else{
                            try ptr.*.out.appendSlice("#|");
                        }
                    },
                    else => {
                        try @"Fn普通正文字符"(ptr);
                    },
                }
            },
            '\n', '\r' => {
                return;
            },
            else => {
                try @"Fn普通正文字符"(ptr);
            },
        }
    }
}

test "Fn格式正文C" {
    var s=try @"Fn新建状态机"("the `a[i]=5;` #|she [[1. while]] #|he #[home#](http://com)\r\n");
    try @"Fn格式正文C"(&s,false);
    try expectEqualSlices(u8,s.out.items,"the <code>a[i]=5;</code> #|she <a href=\"#N1. while\">1. while</a> #|he <a href=\"http://com\">home</a>");

    s.index=0;
    s.out.items.len=0;
    try @"Fn格式正文C"(&s,true);
    try expectEqualSlices(u8,s.out.items,"the <code>a[i]=5;</code> ");
    try expect(s.index==14);

    s.in="#`<!#[pic#](http://.com) ``if(a<5) then{} \r\n";
    s.index=0;
    s.out.items.len=0;
    try @"Fn格式正文C"(&s,false);
    try expectEqualSlices(u8,s.out.items,"`&lt;<img src=\"http://.com\" alt=\"pic\" /> <code>if(a&lt;5) then{} </code>");

    s.in="test `#|` #|test\r\n";
    s.index=0;
    s.out.items.len=0;
    try @"Fn格式正文C"(&s,false);
    try expectEqualSlices(u8,s.out.items,"test <code>#|</code> #|test");

    s.index=0;
    s.out.items.len=0;
    try @"Fn格式正文C"(&s,true);
    try expectEqualSlices(u8,s.out.items,"test <code>#|</code> ");
    @"Fn清空状态机"(&s);
}

// 处理普通正文行
fn @"Fn格式正文行"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<p>");
    try @"Fn格式正文C"(ptr,false);
    try ptr.*.out.appendSlice("</p>\r\n");
    ptr.*.@"上一行状态"=.@"无后续影响";
}

test "Fn格式正文行" {
    var s=try @"Fn新建状态机"("#` `#[` test\r\nabc");
    try @"Fn格式正文行"(&s);
    try expectEqualSlices(u8,s.out.items,"<p>` <code>#[</code> test</p>\r\n");
    @"Fn清空状态机"(&s);
}

//AAA.BBB
//<hN id="NAAA.BBB"><a href="#toc-AAA.BBB">AAA.BBB</a></hN>
//目录：
//<li><a id="toc-AAA.BBB" href="#NAAA.BBB">XXAAA.BBB</a></li>
// 其中N是标题级别，XX是N-1个&nbsp;  &nbsp;是空格的字符实体
// 处理标题行和目录。
fn @"Fn标题行"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var t= if(ptr.*.@"标题级数">6) 6 else  ptr.*.@"标题级数";
    try ptr.*.out.writer().print("<h{} id=\"N",.{t});
    const istart=ptr.*.out.items.len;
    var iend=istart;
    ptr.*.index=ptr.*.@"当前行开始索引";
    while(ptr.*.index<ptr.*.in.len){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            iend=ptr.*.out.items.len;
            break;
        }
        try @"Fn普通正文字符和短代码"(ptr);
    }
    if(ptr.*.index==ptr.*.in.len){
        iend=ptr.*.out.items.len;
    }
    try ptr.*.out.writer().print("\"><a href=\"#toc-{0s}\">{0s}</a></h{1}>\r\n",.{ptr.*.out.items[istart..iend],t});
    try ptr.*.@"目录".writer().print("<li><a id=\"toc-{0s}\" href=\"#N{0s}\">",.{ptr.*.out.items[istart..iend]});
    t-=1;
    while(t>0):(t-=1){
        try ptr.*.@"目录".appendSlice("&nbsp;&nbsp;");
    }
    try ptr.*.@"目录".writer().print("{s}</a></li>",.{ptr.*.out.items[istart..iend]});
    ptr.*.@"上一行状态"=.@"无后续影响";
}

test "Fn标题行" {
    var s=try @"Fn新建状态机"("1.1.2. test\r\nthis is ...");
    @"Fn判断当前行类别"(&s);
    try @"Fn标题行"(&s);
    try expectEqualSlices(u8,s.out.items,"<h3 id=\"N1.1.2. test\"><a href=\"#toc-1.1.2. test\">1.1.2. test</a></h3>\r\n");
    try expectEqualSlices(u8,s.@"目录".items,"<ul>\r\n<li><a id=\"toc-1.1.2. test\" href=\"#N1.1.2. test\">&nbsp;&nbsp;1.1.2. test</a></li>");
    @"Fn清空状态机"(&s);
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
fn @"Fn处理上一行"(ptr:*@"Tprogdoc格式转换状态机") !void{
    switch(ptr.*.@"上一行状态"){
        .@"多行代码行C" => {
            switch(ptr.*.@"当前行类别"){
                .@"多行代码S" => {
                    return progdoc_err.@"当前行是多行代码行S但上一行状态是多行代码行C";
                },
                .@"多行代码SE" => {
                    ptr.*.@"当前行状态"=.@"多行代码行E";
                },
                else => {
                    ptr.*.@"当前行状态"=.@"多行代码行C";
                },
            }
        },
        .@"无后续影响" => {
            switch(ptr.*.@"当前行类别"){
                .@"多行代码S", .@"多行代码SE" => {
                    ptr.*.@"当前行状态"=.@"多行代码行S";
                },
                .@"标题行" => {
                    ptr.*.@"当前行状态"=.@"标题行";
                },
                .@"单行列表行", .@"多行列表行S" => {
                    ptr.*.@"当前行状态"=.@"列表S";
                },
                .@"多行列表行E" => {
                    return progdoc_err.@"多行列表行结束行没有对应的开始行";
                },
                .@"单行表格行", .@"多行表格行SE" => {
                    ptr.*.@"当前行状态"=.@"表格S";
                },
                .@"格式正文行" => {
                    ptr.*.@"当前行状态"=.@"格式正文行";
                },
                .@"内嵌html多行S" => {
                    ptr.*.@"当前行状态"=.@"内嵌html多行S";
                },
                .@"内嵌html多行E" => {
                    return progdoc_err.@"内嵌html结束行没有对应的开始行";
                },
            }
        },
        .@"列表C" => {
            switch(ptr.*.@"当前行类别"){
                .@"格式正文行" => {
                    const e=try ptr.*.@"文档列表栈".get();
                    if(e.@"上一行列表类别"==.@"列表开始单行"){
                        try @"Fn列表E"(ptr);
                        ptr.*.@"当前行状态"=.@"格式正文行";
                    }else{
                        ptr.*.@"当前行状态"=.@"列表C";
                    }
                },
                .@"单行列表行", .@"多行列表行S" ,.@"多行列表行E"=> {
                    ptr.*.@"当前行状态"=.@"列表C";
                },
                .@"多行代码S", .@"多行代码SE" => {
                    try @"Fn列表E"(ptr);
                    ptr.*.@"当前行状态"=.@"多行代码行S";
                },
                .@"标题行" => {
                    try @"Fn列表E"(ptr);
                    ptr.*.@"当前行状态"=.@"标题行";
                },
                .@"单行表格行", .@"多行表格行SE" => {
                    try @"Fn列表E"(ptr);
                    ptr.*.@"当前行状态"=.@"表格S";
                },
                .@"内嵌html多行S" => {
                    try @"Fn列表E"(ptr);
                    ptr.*.@"当前行状态"=.@"内嵌html多行S";
                },
                .@"内嵌html多行E" => {
                    try @"Fn列表E"(ptr);
                    return progdoc_err.@"内嵌html结束行没有对应的开始行";
                },
            }
        },
        .@"表格C" => {
            switch(ptr.*.@"当前行类别"){
                .@"格式正文行" => {
                    try @"Fn表格E"(ptr);
                    ptr.*.@"当前行状态"=.@"格式正文行";
                },
                .@"单行列表行", .@"多行列表行S" => {
                    try @"Fn表格E"(ptr);
                    ptr.*.@"当前行状态"=.@"列表S";
                },
                .@"多行列表行E" => {
                    try @"Fn表格E"(ptr);
                    return progdoc_err.@"多行列表行结束行没有对应的开始行";
                },
                .@"多行代码S", .@"多行代码SE" => {
                    try @"Fn列表E"(ptr);
                    ptr.*.@"当前行状态"=.@"多行代码行S";
                },
                .@"标题行" => {
                    try @"Fn表格E"(ptr);
                    ptr.*.@"当前行状态"=.@"标题行";
                },
                .@"单行表格行", .@"多行表格行SE" => {
                    ptr.*.@"当前行状态"=.@"表格C";
                },
                .@"内嵌html多行S" => {
                    try @"Fn表格E"(ptr);
                    ptr.*.@"当前行状态"=.@"内嵌html多行S";
                },
                .@"内嵌html多行E" => {
                    try @"Fn表格E"(ptr);
                    return progdoc_err.@"内嵌html结束行没有对应的开始行";
                },
            }
        },
        .@"内嵌html多行C" => {
            switch(ptr.*.@"当前行类别"){
                .@"内嵌html多行S" => {
                    return progdoc_err.@"当前行是内嵌html多行S但上一行状态是内嵌html多行C";
                },
                .@"内嵌html多行E" => {
                    ptr.*.@"当前行状态"=.@"内嵌html多行E";
                },
                else => {
                    ptr.*.@"当前行状态"=.@"内嵌html多行C";
                },
            }
        },
    }
}

//找到ch返回true，post值是找到的字符。
//找不到ch返回false，post的值是行尾或字符串尾
//主要用于多行代码行S的文件名解析。
fn @"Fn当前行查找字符"(str:[]const u8,start:usize,ch:u8,post:*usize) bool{
    var i=start;
    while(i<str.len):(i+=1){
        if(str[i]=='\n' or str[i]=='\r'){
            post.*=i;
            return false;
        }
        if(str[i]==ch){
            post.*=i;
            return true;
        }
    }
    post.*=i;
    return false;
}

test "Fn当前行查找字符" {
    var i:usize=undefined;
    try expect(@"Fn当前行查找字符"("abc.de\r\nfg",1,'.',&i));
    try expect(i==3);
    try expect(!@"Fn当前行查找字符"("abc.de\r\nfg",4,'.',&i));
    try expect(i==6);
    try expect(!@"Fn当前行查找字符"("abc.def",4,'.',&i));
    try expect(i==7);
    try expect(!@"Fn当前行查找字符"("abcde",0,'.',&i));
    try expect(i==5);
}

//找到不是ch字符返回true，post值是从start处开始第1个不是ch的字符。
//一直是ch字符返回false，post的值是行尾或字符串尾
//主要用于多行代码行S的文件名解析。
fn @"Fn当前行查找不是ch的字符"(str:[]const u8,start:usize,ch:u8,post:*usize) bool{
    var i=start;
    while(i<str.len):(i+=1){
        if(str[i]=='\n' or str[i]=='\r'){
            post.*=i;
            return false;
        }
        if(str[i]!=ch){
            post.*=i;
            return true;
        }
    }
    post.*=i;
    return false;
}

test "Fn当前行查找不是ch的字符" {
    var i:usize=undefined;
    try expect(@"Fn当前行查找不是ch的字符"("```   abc.doc",0,' ',&i));
    try expect(i==0);
    try expect(@"Fn当前行查找不是ch的字符"("```   abc.doc",3,' ',&i));
    try expect(i==6);
    try expect(!@"Fn当前行查找不是ch的字符"("``   ",3,' ',&i));
    try expect(i==5);
    try expect(!@"Fn当前行查找不是ch的字符"("  \r\nab",0,' ',&i));
    try expect(i==2);
}

//如果有BBB（文件名后缀），则设X="BBB-cap" , Y="file"
//如果无BBB，则设X="AAA-cap" , Y=AAA
//<figure>
// <figcaption class="X">
//  <cite class="Y">AAA.BBB</cite>
// </figcaption>
//<pre><code>
//多行代码行开始处理
fn @"Fn多行代码行S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var @"名字开始":usize=undefined;
    var @"后缀开始":usize=undefined;
    var @"后缀结束":usize=undefined;
    var X:[]const u8=undefined;
    var Y:[]const u8=undefined;
    var Z:[]const u8=undefined;
    if(@"Fn当前行查找不是ch的字符"(ptr.*.in,ptr.*.index,' ',&@"名字开始")){
        if(@"Fn当前行查找字符"(ptr.*.in,@"名字开始",'.',&@"后缀开始")){
            @"后缀开始"+=1;
            _=@"Fn当前行查找字符"(ptr.*.in,@"后缀开始",' ',&@"后缀结束");
            X=ptr.*.in[@"后缀开始"..@"后缀结束"];
            Y="file";
            Z=ptr.*.in[@"名字开始"..@"后缀结束"];
        }else{
            X=ptr.*.in[@"名字开始"..@"后缀开始"];
            Y=X;
            Z=X;
        }
    }else{
        X="";
        Y="";
        Z="";
    }
    try ptr.*.out.writer().print("<figure>\r\n\t<figcaption class=\"{s}-cap\">\r\n",.{X});
    try ptr.*.out.writer().print("\t\t<cite class=\"{s}\">{s}",.{Y,Z});
    try ptr.*.out.appendSlice("</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    while(ptr.*.index<ptr.*.in.len):(ptr.*.index+=1){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            break;
        }
    }
    ptr.*.@"上一行状态"=.@"多行代码行C";
}

test "Fn多行代码行S" {
    var s=try @"Fn新建状态机"("```");
    @"Fn判断当前行类别"(&s);
    try @"Fn多行代码行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<figure>\r\n\t<figcaption class=\"-cap\">\r\n\t\t<cite class=\"\"></cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index==3);
    
    s.in="``` test.zig ";
    s.out.items.len=0;
    s.index=0;
    @"Fn判断当前行类别"(&s);
    try @"Fn多行代码行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index==13);

    s.in="``` test.zig\r\n";
    s.out.items.len=0;
    s.index=0;
    @"Fn判断当前行类别"(&s);
    try @"Fn多行代码行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index==12);

    s.in="```test.zig\r\n";
    s.out.items.len=0;
    s.index=0;
    @"Fn判断当前行类别"(&s);
    try @"Fn多行代码行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<figure>\r\n\t<figcaption class=\"zig-cap\">\r\n\t\t<cite class=\"file\">test.zig</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index==11);

    s.in="```shell\r\n";
    s.out.items.len=0;
    s.index=0;
    @"Fn判断当前行类别"(&s);
    try @"Fn多行代码行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<figure>\r\n\t<figcaption class=\"shell-cap\">\r\n\t\t<cite class=\"shell\">shell</cite>\r\n\t</figcaption>\r\n<pre><code>\r\n");
    try expect(s.index==8);
    @"Fn清空状态机"(&s);
}

//<span class="line">AAA</span>\r\n
//每一代码行的处理
//DEBUG:index要设成当前行开始索引，因为判断行类别时，吃掉了格式前导字符
fn @"Fn多行代码行C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<span class=\"line\">");
    ptr.*.index=ptr.*.@"当前行开始索引";
    while(ptr.*.index<ptr.*.in.len){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            break;
        }
        try @"Fn无格式正文字符"(ptr);
    }
    try ptr.*.out.appendSlice("</span>\r\n");
}

test "Fn多行代码行C" {
    var s=try @"Fn新建状态机"("print(\"#`[]\");  \r\n");
    try @"Fn多行代码行C"(&s);
    try expectEqualSlices(u8,s.out.items,"<span class=\"line\">print(\"#`[]\");  </span>\r\n");
    try expect(s.index==16);
    
    s.in="  #[ #] #--";
    s.index=0;
    s.out.items.len=0;
    try @"Fn多行代码行C"(&s);
    try expectEqualSlices(u8,s.out.items,"<span class=\"line\">  #[ #] #--</span>\r\n");
    try expect(s.index==11);
    @"Fn清空状态机"(&s);
}

//</code></pre></figure>
//多行代码行结尾
fn @"Fn多行代码行E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("</code></pre></figure>\r\n");
    ptr.*.@"上一行状态"=.@"无后续影响";
}

//解析一行，直到行尾或输入尾部。
fn parseline(ptr:*@"Tprogdoc格式转换状态机") !void{
    if(ptr.*.index==ptr.*.in.len){
        ptr.*.@"is输入尾部"=true;
        return;
    }
    errdefer |e| {
        print("解析出错：{s}\n错误位置第{}行，第{}个字符\n出错行：{s}\n",.{@errorName(e),ptr.*.@"行号",ptr.*.index-ptr.*.@"当前行开始索引",ptr.*.in[ptr.*.@"当前行开始索引"..ptr.*.index]});
    }
    @"Fn判断当前行类别"(ptr);
    try @"Fn处理上一行"(ptr);
    switch(ptr.*.@"当前行状态"){
        .@"格式正文行" => {
            try @"Fn格式正文行"(ptr);
        },
        .@"标题行" => {
            try @"Fn标题行"(ptr);
        },
        .@"多行代码行S" => {
            try @"Fn多行代码行S"(ptr);
        },
        .@"多行代码行C" => {
            try @"Fn多行代码行C"(ptr);
        },
        .@"多行代码行E" => {
            try @"Fn多行代码行E"(ptr);
        },
        .@"列表S" => {
            try @"Fn列表S"(ptr);
        },
        .@"列表C" => {
            try @"Fn列表C"(ptr);
        },
        .@"表格S" => {
            try @"Fn表格S"(ptr);
        },
        .@"表格C" => {
            try @"Fn表格C"(ptr);
        },
        .@"内嵌html多行S" => {
            try @"Fn内嵌html多行S"(ptr);
        },
        .@"内嵌html多行C" => {
            try @"Fn内嵌html多行C"(ptr);
        },
        .@"内嵌html多行E" => {
            try @"Fn内嵌html多行E"(ptr);
        },
    }
    const i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"\r\n","\r","\n"});
    if(i==-1){
        ptr.*.@"is输入尾部"=true;
    }
    ptr.*.@"当前行开始索引"=ptr.*.index;
    ptr.*.@"行号"+=1;
}

// #<<
// 内嵌html多行的开始处理
fn @"Fn内嵌html多行S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    @"Fn到行尾"(ptr);
    ptr.*.@"上一行状态"=.@"内嵌html多行C";
}

// 不进行任何实体替换或其它处理，原样输出内嵌html行
fn @"Fn内嵌html多行C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    while(ptr.*.index<ptr.*.in.len):(ptr.*.index+=1){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            break;
        }
        try ptr.*.out.append(ptr.*.in[ptr.*.index]);
    }
}

// #>>
// 内嵌html结束处理
fn @"Fn内嵌html多行E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    @"Fn到行尾"(ptr);
    ptr.*.@"上一行状态"=.@"无后续影响";
}

test "parseline 内嵌html" {
    var s=try @"Fn新建状态机"("#<<  \n<a>test `#[[</a>\n#>>aa\nbbb\n#>>>");
    try parseline(&s);
    try expect(s.@"当前行类别"==.@"内嵌html多行S");
    try expect(s.@"上一行状态"==.@"内嵌html多行C");
    try parseline(&s);
    try expectEqualSlices(u8,s.out.items,"<a>test `#[[</a>");
    try parseline(&s);
    try expect(s.@"当前行类别"==.@"内嵌html多行E");
    try parseline(&s);
    try expectEqualSlices(u8,s.out.items,"<a>test `#[[</a><p>bbb</p>\r\n");
    try expectError(progdoc_err.@"内嵌html结束行没有对应的开始行", parseline(&s));
    @"Fn清空状态机"(&s);
}

test "parseline 多行代码1" {
    var s=try @"Fn新建状态机"("ab\r``` test.zig\r\nprint;\nmain() void\r\n```\n1.1. toc");
    try parseline(&s);
    try expect(s.@"当前行开始索引"==3);
    try expect(s.out.items.len==11);

    try parseline(&s);
    try expect(s.@"当前行开始索引"==17);
    try expect(s.out.items.len==119);

    try parseline(&s);
    try expect(s.@"当前行开始索引"==24);
    try expect(s.out.items.len==153);

    try parseline(&s);
    try expect(s.@"当前行开始索引"==37);
    try expect(s.out.items.len==192);

    try parseline(&s);
    try expect(s.@"当前行开始索引"==41);
    try expect(s.out.items.len==216);
    try expect(!s.@"is输入尾部");

    try parseline(&s);
    try expect(s.@"当前行开始索引"==49);
    try expect(s.out.items.len==278);
    try expect(s.@"is输入尾部");
    @"Fn清空状态机"(&s);
}
test "parseline 多行代码2" {
    var s=try @"Fn新建状态机"("```\r\nprint;\n``` test.zig\r\n");
    try parseline(&s);
    try parseline(&s);
    try expectError(progdoc_err.@"当前行是多行代码行S但上一行状态是多行代码行C",parseline(&s));
    @"Fn清空状态机"(&s);
}

// 列表栈操作，列表栈长度固定为7，一方面占用内存极小不用再省了，一方面7层级列表足够用了。层级太多需要整理思路重新写。
// 第一级列表在列表栈[0]，第二级列表在[1]，依此类推。
// 当列表栈isempty时，表明列表正确结束。
// 当前列表中，多行列表行S则压栈，增加1级，多行列表行E则出栈，减少1级。
// 列表栈[0]较特殊，只有 列表开始单行 和 列表开始多行2 两种类别，因为对应的是整个列表的开始。
const @"列表栈长度":usize=7;
const @"T列表栈"=struct{
    top:i4=-1,
    entry:[@"列表栈长度"]@"T列表栈项"=undefined,
    fn push(self:*@"T列表栈",a:@"T上一行列表类别",b:@"T上一行列表状态") !void{
        self.top+=1;
        if(self.top==@"列表栈长度"){
            return progdoc_err.@"push时列表栈满";
        }
        self.entry[@intCast(usize,self.top)].@"上一行列表类别"=a;
        self.entry[@intCast(usize,self.top)].@"上一行列表状态"=b;
    }
    fn pop(self:*@"T列表栈") !void{
        if(self.top==-1){
            return progdoc_err.@"pop时列表栈空";
        }
        self.top-=1;
    }
    fn get(self:@"T列表栈") !@"T列表栈项"{
        if(self.top==-1){
            return progdoc_err.@"get时列表栈空";
        }
        return self.entry[@intCast(usize,self.top)];
    }
    fn set(self:*@"T列表栈",b:@"T上一行列表状态") !void{
        if(self.top==-1){
            return progdoc_err.@"set时列表栈空";
        }
        self.entry[@intCast(usize,self.top)].@"上一行列表状态"=b;
    }
    fn empty(self:*@"T列表栈") void{
        self.top=-1;
    }
    fn isempty(self:@"T列表栈") bool{
        return self.top==-1;
    }
};
const @"T列表栈项"=packed struct{
    @"上一行列表类别":@"T上一行列表类别",
    @"上一行列表状态":@"T上一行列表状态",
};
const @"T上一行列表类别"=enum(u2){
    @"列表开始单行",    //整个列表的开始行，是#-
    @"列表开始多行2",   //整个列表的开始行，是#--
    @"多行列表行1",     // 1是在单行列表行后面，不需要 <ul>
    @"多行列表行2",     // 2是在列表正文后，需要 <ul>
};
const @"T上一行列表状态"=enum(u2){
    @"单行列表行C",
    @"多行列表行正文项",
};

test "列表栈" {
    var state=try @"Fn新建状态机"("");
    var s=state.@"文档列表栈";
    try expect(s.top==-1);
    try expectError(progdoc_err.@"get时列表栈空",s.get());
    try expectError(progdoc_err.@"pop时列表栈空",s.pop());
    try expect(s.isempty());

    try s.push(.@"多行列表行1",.@"单行列表行C");
    try expect(s.top==0);
    var x=try s.get();
    try expect(x.@"上一行列表类别"==.@"多行列表行1");
    try expect(x.@"上一行列表状态"==.@"单行列表行C");
    try s.set(.@"多行列表行正文项");
    x=try s.get();
    try expect(x.@"上一行列表状态"==.@"多行列表行正文项");

    s.top=6;
    try expectError(progdoc_err.@"push时列表栈满",s.push(.@"多行列表行1",.@"单行列表行C"));
    @"Fn清空状态机"(&state);
}

//单行列表项要加 </li>
inline fn @"Fn单行列表行列表项"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<li>");
    try @"Fn格式正文C"(ptr,false);
    try ptr.*.out.appendSlice("</li>\r\n");
}
//多行列表项开始 <li> ，结尾没有 </li>
//多行列表项与单行列表项的区别还有，要加<span>
inline fn @"Fn多行列表行列表项"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<li><span>");
    try @"Fn格式正文C"(ptr,false);
    try ptr.*.out.appendSlice("</span>\r\n");
}
//多行正文项开始没有 <li>
inline fn @"Fn多行列表行格式正文C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<span>");
    try @"Fn格式正文C"(ptr,false);
    try ptr.*.out.appendSlice("</span>\r\n");
}

//列表开始处理
//状态表
//单行列表行    push(列表开始单行,单行列表行C)      单行列表项
//多行列表行S   push(列表开始多行,多行列表行正文项)  多行列表项
fn @"Fn列表S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"文档列表栈";
    assert(stack.*.isempty());
    switch(ptr.*.@"当前行类别"){
        .@"单行列表行" => {
            try ptr.*.out.appendSlice("<ul>\r\n");
            try stack.*.push(.@"列表开始单行",.@"单行列表行C");
            try @"Fn单行列表行列表项"(ptr);
        },
        .@"多行列表行S" => {
            try ptr.*.out.appendSlice("<ul>\r\n");
            try stack.*.push(.@"列表开始多行2",.@"多行列表行正文项");
            try @"Fn多行列表行列表项"(ptr);
        },
        else => {
            unreachable;
        },
    }
    ptr.*.@"上一行状态"=.@"列表C";
}
test "Fn列表S" {
    var s=try @"Fn新建状态机"("#- test`#-`");
    @"Fn判断当前行类别"(&s);
    try @"Fn列表S"(&s);
    try expectEqualSlices(u8,s.out.items,"<ul>\r\n<li> test<code>#-</code></li>\r\n");

    s.in="#-- test [[aa]]\r\naa";
    s.@"当前行开始索引"=0;
    s.out.items.len=0;
    s.@"文档列表栈".empty();
    @"Fn判断当前行类别"(&s);
    try @"Fn列表S"(&s);
    try expectEqualSlices(u8,s.out.items,"<ul>\r\n<li><span> test <a href=\"#Naa\">aa</a></span>\r\n");
    @"Fn清空状态机"(&s);
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
fn @"Fn列表C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"文档列表栈";
    const e=try stack.*.get();
    switch(ptr.*.@"当前行类别"){
        .@"单行列表行" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try ptr.*.out.appendSlice("<ul>\r\n");
                try stack.*.set(.@"单行列表行C");
            }
            try @"Fn单行列表行列表项"(ptr);
        },
        .@"多行列表行S" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try stack.*.push(.@"多行列表行2",.@"多行列表行正文项");
                try ptr.*.out.appendSlice("<ul>\r\n");
            }else{
                try stack.*.push(.@"多行列表行1",.@"多行列表行正文项");
            }
            try @"Fn多行列表行列表项"(ptr);
        },
        .@"格式正文行" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try ptr.*.out.appendSlice("<br />");
            }else{
                try ptr.*.out.appendSlice("</ul>\r\n");
                try stack.*.set(.@"多行列表行正文项");
            }
            try @"Fn多行列表行格式正文C"(ptr);
        },
        .@"多行列表行E" => {
            if(e.@"上一行列表类别"==.@"列表开始单行"){
                return progdoc_err.@"多行列表行结束行没有对应的开始行";
            }
            if(e.@"上一行列表状态"==.@"单行列表行C"){
                try ptr.*.out.appendSlice("</ul>\r\n");
            }
            try ptr.*.out.appendSlice("</li>\r\n");
            if(e.@"上一行列表类别"==.@"多行列表行2" or e.@"上一行列表类别"==.@"列表开始多行2"){
                try ptr.*.out.appendSlice("</ul>\r\n");
            }
            try stack.*.pop();
            if(stack.*.isempty()){
                ptr.*.@"上一行状态"=.@"无后续影响";
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
fn @"Fn列表E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"文档列表栈";
    const e=try stack.*.get();
    switch(e.@"上一行列表类别") {
        .@"列表开始单行" => {
            try ptr.*.out.appendSlice("</ul>\r\n");
            try stack.*.pop();
            assert(stack.*.isempty());
            ptr.*.@"上一行状态"=.@"无后续影响";
        },
        else => {
            return progdoc_err.@"多行列表行没有对应的结束行";
        },
    }
}

test "parseline 单行列表" {
    var s=try @"Fn新建状态机"("a\n#- aaa\n #- bbb\n  \t #- ccc\n d");
    try parseline(&s);
    try expectEqualSlices(u8,s.out.items,"<p>a</p>\r\n");
    try parseline(&s);
    try expectEqualSlices(u8,s.out.items,"<p>a</p>\r\n<ul>\r\n<li> aaa</li>\r\n");
    try parseline(&s);
    try parseline(&s);
    try parseline(&s);
    try expectEqualSlices(u8,s.out.items,"<p>a</p>\r\n<ul>\r\n<li> aaa</li>\r\n<li> bbb</li>\r\n<li> ccc</li>\r\n</ul>\r\n<p> d</p>\r\n");
    @"Fn清空状态机"(&s);
}

test "parseline 多行列表"{
    var s=try @"Fn新建状态机"("#--a\na1\na2\n#-b\n#-b1\na3\n#-c1\na4\n#--");
    while(s.@"当前行开始索引"<s.in.len){
        try parseline(&s);
    }
    try expectEqualSlices(u8,s.out.items,"<ul>\r\n<li><span>a</span>\r\n<br /><span>a1</span>\r\n<br /><span>a2</span>\r\n<ul>\r\n<li>b</li>\r\n<li>b1</li>\r\n</ul>\r\n<span>a3</span>\r\n<ul>\r\n<li>c1</li>\r\n</ul>\r\n<span>a4</span>\r\n</li>\r\n</ul>\r\n");
    @"Fn清空状态机"(&s);

    var s1=try @"Fn新建状态机"("#--a\n#--b\nb1\n#-bb1\n#-bb2\n#--\n#--");
    while(s1.@"当前行开始索引"<s1.in.len){
        try parseline(&s1);
    }
    try expectEqualSlices(u8,s1.out.items,"<ul>\r\n<li><span>a</span>\r\n<ul>\r\n<li><span>b</span>\r\n<br /><span>b1</span>\r\n<ul>\r\n<li>bb1</li>\r\n<li>bb2</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n");
    @"Fn清空状态机"(&s1);
}

test "parseline 列表错误" {
    var s=try @"Fn新建状态机"("#--a\na1\n``` test.zig\n");
    try parseline(&s);
    try parseline(&s);
    try expectError(progdoc_err.@"多行列表行没有对应的结束行",parseline(&s));
    @"Fn清空状态机"(&s);

    var s1=try @"Fn新建状态机"("a\n#--");
    try parseline(&s1);
    try expectError(progdoc_err.@"多行列表行结束行没有对应的开始行",parseline(&s1));
    @"Fn清空状态机"(&s1);
}

//主要是为了区分普通正文和列表用
fn @"Fn判断表格单元格类别"(ptr:*@"Tprogdoc格式转换状态机") void{
    var i=ptr.*.index;
    while(i<ptr.*.in.len):(i+=1){
        if(ptr.*.in[i]!=' ' and ptr.*.in[i]!='\t'){
            break;
        }
        if(ptr.*.in[i]=='\n' or ptr.*.in[i]=='\r'){
            break;
        }
    }
    var j=@"Fnis包含字符串"(ptr.*.in,&i,.{"#--\r","#--\n","#--#|","#--","#-"});
    switch(j) {
        0,1 => {
            ptr.*.@"当前表格单元格类别"=.@"多行列表行E";
            i-=1;
        },
        2 => {
            ptr.*.@"当前表格单元格类别"=.@"多行列表行E";
            i-=2;
        },
        3 => {
            if(i==ptr.*.in.len){
                ptr.*.@"当前表格单元格类别"=.@"多行列表行E";
            }else{
                ptr.*.@"当前表格单元格类别"=.@"多行列表行S";
            }
        },
        4 => {
            ptr.*.@"当前表格单元格类别"=.@"单行列表行";
        },
        else => {
            i=ptr.*.index;
            ptr.*.@"当前表格单元格类别"=.@"格式正文行";
        },
    }
    ptr.*.index=i;
}

test "Fn判断表格单元格类别" {
    var s=try @"Fn新建状态机"("#|   #|  #| #- \n");
    s.index=2;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==2);
    try expect(s.@"当前表格单元格类别"==.@"格式正文行");

    s.index=7;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==7);
    try expect(s.@"当前表格单元格类别"==.@"格式正文行");

    s.in="#|#--#|#- a#|  #-b #|  #--\n#|   #-- cc #|#--";
    s.index=2;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==5);
    try expect(s.@"当前表格单元格类别"==.@"多行列表行E");

    s.index=7;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==9);
    try expect(s.@"当前表格单元格类别"==.@"单行列表行");

    s.index=13;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==17);
    try expect(s.@"当前表格单元格类别"==.@"单行列表行");

    s.index=21;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==26);
    try expect(s.@"当前表格单元格类别"==.@"多行列表行E");

    s.index=29;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==35);
    try expect(s.@"当前表格单元格类别"==.@"多行列表行S");

    s.index=41;
    @"Fn判断表格单元格类别"(&s);
    try expect(s.index==44);
    try expect(s.@"当前表格单元格类别"==.@"多行列表行E");

    @"Fn清空状态机"(&s);
}


//如果列号对应的列表栈为空，则表示当前没有列表。
//单元格列表栈          空          非空
//格式正文行            格正文C     if(列表开始单行) 格列表E|格正文C else 格列表C
//单行列表、多行列表S    格列表S      格列表C
//多行列表E             ERR         格列表C
fn @"Fn填写表格单元格内容"(ptr:*@"Tprogdoc格式转换状态机") !void{
    const e=ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"].isempty();
    switch(ptr.*.@"当前表格单元格类别"){
        .@"格式正文行" => {
            if(e){
                try @"Fn表格单元格格式正文C"(ptr);
            }else{
                const i=try ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"].get();
                if(i.@"上一行列表类别"==.@"列表开始单行"){
                    try @"Fn表格单元格列表E"(ptr);
                    try @"Fn表格单元格格式正文C"(ptr);
                }else{
                    try @"Fn表格单元格列表C"(ptr);
                }
            }
        },
        .@"单行列表行", .@"多行列表行S" => {
            if(e){
                try @"Fn表格单元格列表S"(ptr);
            }else{
                try @"Fn表格单元格列表C"(ptr);
            }
        },
        .@"多行列表行E" => {
            if(e){
                return progdoc_err.@"多行列表行结束行没有对应的开始行";
            }else{
                try @"Fn表格单元格列表C"(ptr);
            }
        },
    }
}

test "Fn填写表格单元格内容" {
    var s=try @"Fn新建状态机"("#| ab#|");
    try s.@"表格单元格列表栈".append(.{});
    s.index=2;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    try expectEqualSlices(u8,s.out.items," ab");

    s.in="#|#-- a1 #|a2 #| #- ab1 #| #- ab2 #| #-- ac1 #| #--#| #--";
    s.index=2;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=11;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=16;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=26;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=36;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=47;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    s.index=53;
    @"Fn判断表格单元格类别"(&s);
    try @"Fn填写表格单元格内容"(&s);
    try expectEqualSlices(u8,s.out.items," ab<ul>\r\n<li><span> a1 </span>\r\n<br /><span>a2 </span>\r\n<ul>\r\n<li> ab1 </li>\r\n<li> ab2 </li>\r\n<li><span> ac1 </span>\r\n</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n");

    @"Fn清空状态机"(&s);
}

inline fn @"Fn表格单元格格式正文C"(ptr:*@"Tprogdoc格式转换状态机") !void {
    try @"Fn格式正文C"(ptr,true);
}
inline fn @"Fn表格单元格单行列表行列表项"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<li>");
    try @"Fn格式正文C"(ptr,true);
    try ptr.*.out.appendSlice("</li>\r\n");
}
inline fn @"Fn表格单元格多行列表行列表项"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<li><span>");
    try @"Fn格式正文C"(ptr,true);
    try ptr.*.out.appendSlice("</span>\r\n");
}
inline fn @"Fn表格单元格多行列表行格式正文C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<span>");
    try @"Fn格式正文C"(ptr,true);
    try ptr.*.out.appendSlice("</span>\r\n");
}

//格单列表行    <ul>|push(开始单行，单行C)|格单行列表项
//格多列表行S   <ul>|push(开始多行2，正文项)|格多行列表项
fn @"Fn表格单元格列表S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"];
    assert(stack.*.isempty());
    switch(ptr.*.@"当前表格单元格类别"){
        .@"单行列表行" => {
            try ptr.*.out.appendSlice("<ul>\r\n");
            try stack.*.push(.@"列表开始单行",.@"单行列表行C");
            try @"Fn表格单元格单行列表行列表项"(ptr);
        },
        .@"多行列表行S" => {
            try ptr.*.out.appendSlice("<ul>\r\n");
            try stack.*.push(.@"列表开始多行2",.@"多行列表行正文项");
            try @"Fn表格单元格多行列表行列表项"(ptr);
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
fn @"Fn表格单元格列表C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"];
    const e=try stack.*.get();
    switch(ptr.*.@"当前表格单元格类别"){
        .@"单行列表行" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try ptr.*.out.appendSlice("<ul>\r\n");
                try stack.*.set(.@"单行列表行C");
            }
            try @"Fn表格单元格单行列表行列表项"(ptr);
        },
        .@"多行列表行S" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try stack.*.push(.@"多行列表行2",.@"多行列表行正文项");
                try ptr.*.out.appendSlice("<ul>\r\n");
            }else{
                try stack.*.push(.@"多行列表行1",.@"多行列表行正文项");
            }
            try @"Fn表格单元格多行列表行列表项"(ptr);
        },
        .@"格式正文行" => {
            if(e.@"上一行列表状态"==.@"多行列表行正文项"){
                try ptr.*.out.appendSlice("<br />");
            }else{
                try ptr.*.out.appendSlice("</ul>\r\n");
                try stack.*.set(.@"多行列表行正文项");
            }
            try @"Fn表格单元格多行列表行格式正文C"(ptr);
        },
        .@"多行列表行E" => {
            if(e.@"上一行列表类别"==.@"列表开始单行"){
                return progdoc_err.@"多行列表行结束行没有对应的开始行";
            }
            if(e.@"上一行列表状态"==.@"单行列表行C"){
                try ptr.*.out.appendSlice("</ul>\r\n");
            }
            try ptr.*.out.appendSlice("</li>\r\n");
            if(e.@"上一行列表类别"==.@"多行列表行2" or e.@"上一行列表类别"==.@"列表开始多行2"){
                try ptr.*.out.appendSlice("</ul>\r\n");
            }
            try stack.*.pop();
        },
    }
}

//列表开始单行  </ul>|pop|assert(isempty)
//其它（多行类） ERR
fn @"Fn表格单元格列表E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    var stack=&ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"];
    const e=try stack.*.get();
    switch(e.@"上一行列表类别") {
        .@"列表开始单行" => {
            try ptr.*.out.appendSlice("</ul>\r\n");
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
fn @"Fn表格开始单行"(ptr:*@"Tprogdoc格式转换状态机") !void{
    ptr.*.@"上一行表格状态"=.@"单行表格行C";
    try ptr.*.out.appendSlice("<tr>\r\n");
    while(ptr.*.index<ptr.*.in.len){
        try ptr.*.@"表格单元格列表栈".append(.{});
        var i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"<",">","^"});
        var @"对齐str":[]const u8=undefined;
        if(i!=-1){
            @"对齐str"=switch(i) {
                0 => "t_left",
                1 => "t_right",
                2 => "t_center",
                else => "",
            };
        try ptr.*.out.writer().print("<td class=\"{s}\">",.{@"对齐str"});
        }else{
            try ptr.*.out.appendSlice("<td>");
        }
        try @"Fn表格单元格格式正文C"(ptr);
        try ptr.*.out.appendSlice("</td>\r\n");
        ptr.*.@"表格当前列序号"+=1;
        if(ptr.*.index==ptr.*.in.len){
            break;
        }
        i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#|","\r","\n"});
        assert(i!=-1);
        if(i!=0){
            ptr.*.index-=1;
            break;
        }
    }
    try ptr.*.out.appendSlice("</tr>\r\n");
    ptr.*.@"表格总列数"=ptr.*.@"表格当前列序号";
    ptr.*.@"表格当前列序号"=0;
}

test "Fn表格开始单行" {
    //表格中不能用行代码
    var s=try @"Fn新建状态机"("#|<1.1.aa #|>#`#`#`bb #|^c[[c]] #| #-dd #|  #--ee\r\n");
    @"Fn判断当前行类别"(&s);
    try @"Fn表格开始单行"(&s);
    try expect(s.@"表格总列数"==5);
    try expect(s.@"表格单元格列表栈".items.len==5);
    try expectEqualSlices(u8,s.out.items,"<tr>\r\n<td class=\"t_left\">1.1.aa </td>\r\n<td class=\"t_right\">```bb </td>\r\n<td class=\"t_center\">c<a href=\"#Nc\">c</a> </td>\r\n<td> #-dd </td>\r\n<td>  #--ee</td>\r\n</tr>\r\n");
    @"Fn清空状态机"(&s);
}

//单行C要处理每行的对齐。
//如果当前列数不等于总列数，则ERR
fn @"Fn表格行单行C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<tr>\r\n");
    while(ptr.*.index<ptr.*.in.len){
        var i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"<",">","^"});
        var @"对齐str":[]const u8=undefined;
        if(i!=-1){
            @"对齐str"=switch(i) {
                0 => "t_left",
                1 => "t_right",
                2 => "t_center",
                else => "",
            };
        try ptr.*.out.writer().print("<td class=\"{s}\">",.{@"对齐str"});
        }else{
            try ptr.*.out.appendSlice("<td>");
        }
        try @"Fn表格单元格格式正文C"(ptr);
        try ptr.*.out.appendSlice("</td>\r\n");
        ptr.*.@"表格当前列序号"+=1;
        if(ptr.*.index==ptr.*.in.len){
            break;
        }
        i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#|","\r","\n"});
        assert(i!=-1);
        if(i!=0){
            ptr.*.index-=1;
            break;
        }
    }
    if(ptr.*.@"表格当前列序号"!=ptr.*.@"表格总列数"){
        return progdoc_err.@"与上一行表格列数不相等";
    }
    try ptr.*.out.appendSlice("</tr>\r\n");
    ptr.*.@"表格当前列序号"=0;
}

test "Fn表格行单行C" {
    var s=try @"Fn新建状态机"("#|<a1#|b1#|c1\r\n#|a2#|b2#|c2\r\n#|a3#|b3#|c3\r\n");
    @"Fn判断当前行类别"(&s);
    try @"Fn表格开始单行"(&s);
    try expect(s.@"表格总列数"==3);
    s.@"当前行开始索引"=15;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行单行C"(&s);
    s.@"当前行开始索引"=29;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行单行C"(&s);
    try expectEqualSlices(u8,s.out.items,"<tr>\r\n<td class=\"t_left\">a1</td>\r\n<td>b1</td>\r\n<td>c1</td>\r\n</tr>\r\n<tr>\r\n<td>a2</td>\r\n<td>b2</td>\r\n<td>c2</td>\r\n</tr>\r\n<tr>\r\n<td>a3</td>\r\n<td>b3</td>\r\n<td>c3</td>\r\n</tr>\r\n");

    s.@"当前行开始索引"=0;
    s.index=0;
    s.in="#| 12";
    @"Fn判断当前行类别"(&s);
    try expectError(progdoc_err.@"与上一行表格列数不相等",@"Fn表格行单行C"(&s));
    @"Fn清空状态机"(&s);
}

//开始行要处理对齐，设定总列数，单元格列表栈、多行缓冲要搞到总列数数量。
//多行每个单元格要切换out，以输出到多行缓冲二维动态数组中。
fn @"Fn表格开始多行"(ptr:*@"Tprogdoc格式转换状态机") !void{
    ptr.*.@"上一行表格状态"=.@"多行表格行C";
    try ptr.*.out.appendSlice("<tr>\r\n");
    const x=ptr.*.out;
    while(ptr.*.index<ptr.*.in.len){
        try ptr.*.@"表格单元格列表栈".append(.{});
        try ptr.*.@"多行表格行缓冲".@"Fn增加多行表格行单元格缓冲"();
        var i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"<",">","^"});
        var @"对齐str":[]const u8=undefined;
        ptr.*.@"多行表格temp".items.len=0;
        ptr.*.out=ptr.*.@"多行表格temp";
        if(i!=-1){
            @"对齐str"=switch(i) {
                0 => "t_left",
                1 => "t_right",
                2 => "t_center",
                else => "",
            };
        try ptr.*.out.writer().print("<td class=\"{s}\">",.{@"对齐str"});
        }else{
            try ptr.*.out.appendSlice("<td>");
        }
        @"Fn判断表格单元格类别"(ptr);
        try @"Fn填写表格单元格内容"(ptr);
        try ptr.*.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(ptr.*.@"表格当前列序号",ptr.*.out.items);
        ptr.*.@"表格当前列序号"+=1;
        if(ptr.*.index==ptr.*.in.len){
            break;
        }
        i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#|","\r","\n"});
        assert(i!=-1);
        if(i!=0){
            ptr.*.index-=1;
            break;
        }
    }
    ptr.*.out=x;
    ptr.*.@"表格总列数"=ptr.*.@"表格当前列序号";
    ptr.*.@"表格当前列序号"=0;
}

//多行表格行的后续行对齐无用，不处理对齐，以第1行为准。
//多行表格行的后续行单元格不加<td>
//如果当前列数不等于总列数，则ERR
fn @"Fn表格行多行C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    const x=ptr.*.out;
    while(ptr.*.index<ptr.*.in.len){
        ptr.*.@"多行表格temp".items.len=0;
        ptr.*.out=ptr.*.@"多行表格temp";
        if(ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"].isempty()){
            try ptr.*.out.appendSlice("<br />");
        }
        @"Fn判断表格单元格类别"(ptr);
        try @"Fn填写表格单元格内容"(ptr);
        try ptr.*.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(ptr.*.@"表格当前列序号",ptr.*.out.items);
        ptr.*.@"表格当前列序号"+=1;
        if(ptr.*.index==ptr.*.in.len){
            break;
        }
        var i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#|","\r","\n"});
        assert(i!=-1);
        if(i!=0){
            ptr.*.index-=1;
            break;
        }
    }
    if(ptr.*.@"表格当前列序号"!=ptr.*.@"表格总列数"){
        return progdoc_err.@"与上一行表格列数不相等";
    }
    ptr.*.@"表格当前列序号"=0;
    ptr.*.out=x;
}

//表格中间，多行S要处理对齐，每1个单元格前要加<td>
//注意要判断是否多行缓冲是空，空的话则增加。
fn @"Fn表格行多行S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    if(ptr.*.@"多行表格行缓冲".@"使用长度"==0){
        var i:usize=0;
        while(i<ptr.*.@"表格总列数"):(i+=1){
            try ptr.*.@"多行表格行缓冲".@"Fn增加多行表格行单元格缓冲"();
        }
    }
    ptr.*.@"上一行表格状态"=.@"多行表格行C";
    try ptr.*.out.appendSlice("<tr>\r\n");
    const x=ptr.*.out;
    while(ptr.*.index<ptr.*.in.len){
        ptr.*.@"多行表格temp".items.len=0;
        ptr.*.out=ptr.*.@"多行表格temp";
        var i=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"<",">","^"});
        var @"对齐str":[]const u8=undefined;
        if(i!=-1){
            @"对齐str"=switch(i) {
                0 => "t_left",
                1 => "t_right",
                2 => "t_center",
                else => "",
            };
        try ptr.*.out.writer().print("<td class=\"{s}\">",.{@"对齐str"});
        }else{
            try ptr.*.out.appendSlice("<td>");
        }
        @"Fn判断表格单元格类别"(ptr);
        try @"Fn填写表格单元格内容"(ptr);
        try ptr.*.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲追加字符串"(ptr.*.@"表格当前列序号",ptr.*.out.items);
        ptr.*.@"表格当前列序号"+=1;
        if(ptr.*.index==ptr.*.in.len){
            break;
        }
        var j=@"Fnis包含字符串"(ptr.*.in,&ptr.*.index,.{"#|","\r","\n"});
        assert(j!=-1);
        if(j!=0){
            ptr.*.index-=1;
            break;
        }
    }
    if(ptr.*.@"表格当前列序号"!=ptr.*.@"表格总列数"){
        return progdoc_err.@"与上一行表格列数不相等";
    }
    ptr.*.@"表格当前列序号"=0;
    ptr.*.out=x;
}

//多行结束，每单元格后加</td>；将多行缓冲追加到out输出；清空多行缓冲。
//DEBUG：多行结束时没有判断单元格列表结束与否。
//DEBUG:循环变量原来用的是i,而不是表格当前列序号
fn @"Fn表格行多行E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    ptr.*.@"上一行表格状态"=.@"单行表格行C";
    try ptr.*.@"多行表格行缓冲".@"Fn多行表格行单元格缓冲全部追加字符串"("</td>\r\n");
    while(ptr.*.@"表格当前列序号"<ptr.*.@"表格总列数"):(ptr.*.@"表格当前列序号"+=1){
        if(!ptr.*.@"表格单元格列表栈".items[ptr.*.@"表格当前列序号"].isempty()){
            try @"Fn表格单元格列表E"(ptr);
        }
        var x=try ptr.*.@"多行表格行缓冲".@"Fn获取多行表格行单元格缓冲"(ptr.*.@"表格当前列序号");
        try ptr.*.out.appendSlice(x.items);
    }
    try ptr.*.out.appendSlice("</tr>\r\n");
    ptr.*.@"多行表格行缓冲".@"Fn清空多行表格行单元格缓冲"();
    for(ptr.*.@"表格单元格列表栈".items) |v| {
        assert(v.isempty());
    }
    ptr.*.@"表格当前列序号"=0;
}

test "Fn表格行多行" {
    var s=try @"Fn新建状态机"("#|<a1#|#--b1#|c1\r\n#|a2#|^b2#|#-c2\r\n#|a3#|#-b3#|#-c3\r\n#|#|#--#|#\r\n");
    @"Fn判断当前行类别"(&s);
    try @"Fn表格开始多行"(&s);
    try expect(s.@"表格总列数"==3);
    s.@"当前行开始索引"=s.index+2;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行多行C"(&s);
    s.@"当前行开始索引"=s.index+2;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行多行C"(&s);
    s.@"当前行开始索引"=s.index+2;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行多行C"(&s);
    try @"Fn表格行多行E"(&s);
    try expectEqualSlices(u8,s.out.items,"<tr>\r\n<td class=\"t_left\">a1<br />a2<br />a3<br /></td>\r\n<td><ul>\r\n<li><span>b1</span>\r\n<br /><span>^b2</span>\r\n<ul>\r\n<li>b3</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n</td>\r\n<td>c1<br /><ul>\r\n<li>c2</li>\r\n<li>c3</li>\r\n</ul>\r\n#</td>\r\n</tr>\r\n");

    s.in="#|aa#|bb#|cc";
    s.@"当前行开始索引"=0;
    s.index=0;
    s.out.items.len=0;
    @"Fn判断当前行类别"(&s);
    try @"Fn表格行多行S"(&s);
    try expectEqualSlices(u8,s.out.items,"<tr>\r\n");
    try expectEqualSlices(u8,s.@"多行表格行缓冲".@"单元格".items[0].items,"<td>aa");
    try expectEqualSlices(u8,s.@"多行表格行缓冲".@"单元格".items[1].items,"<td>bb");
    try expectEqualSlices(u8,s.@"多行表格行缓冲".@"单元格".items[2].items,"<td>cc");

    @"Fn清空状态机"(&s);
}

// 从当前待解析字符位置到行尾或输入尾
// 用于 #|- #<< 等行，忽略同一行的后面字符。
fn @"Fn到行尾"(ptr:*@"Tprogdoc格式转换状态机") void{
    while(ptr.*.index<ptr.*.in.len):(ptr.*.index+=1){
        if(ptr.*.in[ptr.*.index]=='\n' or ptr.*.in[ptr.*.index]=='\r'){
            break;
        }
    }
}

//表格S状态表
//                动作          上一行表格状态
//单行表格行     Fn表格开始单行     单行表格行C
//多行表格行SE   Fn到行尾          多行表格开始行
fn @"Fn表格S"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("<table>\r\n");
    switch(ptr.*.@"当前行类别"){
        .@"单行表格行" => {
            try @"Fn表格开始单行"(ptr);
            ptr.*.@"上一行表格状态"=.@"单行表格行C";
        },
        .@"多行表格行SE" => {
            @"Fn到行尾"(ptr);
            ptr.*.@"上一行表格状态"=.@"多行表格开始行";
        },
        else => {
            unreachable;
        },
    }
    ptr.*.@"上一行状态"=.@"表格C";
}

//          单行表格行C                   多行表格开始行    多行表格行开始行    多行表格行C
//单行表格行  Fn表格行单行C                Fn表格开始多行    F表格行多行S      Fn表格行多行C
//多行表格SE            Fn到行尾
//          上一行表格状态:多行表格开始行     ERR           ERR              Fn表格行多行E
fn @"Fn表格C"(ptr:*@"Tprogdoc格式转换状态机") !void{
    switch(ptr.*.@"当前行类别"){
        .@"单行表格行" => {
            switch(ptr.*.@"上一行表格状态") {
                .@"单行表格行C" => {
                    try @"Fn表格行单行C"(ptr);
                },
                .@"多行表格开始行" => {
                    try @"Fn表格开始多行"(ptr);
                },
                .@"多行表格行开始行" => {
                    try @"Fn表格行多行S"(ptr);
                },
                .@"多行表格行C" => {
                    try @"Fn表格行多行C"(ptr);
                }
            }
        },
        .@"多行表格行SE" => {
            @"Fn到行尾"(ptr);
            switch(ptr.*.@"上一行表格状态") {
                .@"单行表格行C" => {
                    ptr.*.@"上一行表格状态"=.@"多行表格行开始行";
                },
                .@"多行表格开始行",.@"多行表格行开始行" => {
                    return progdoc_err.@"多行表格行是空行";
                },
                .@"多行表格行C" => {
                    try @"Fn表格行多行E"(ptr);
                }
            }
        },
        else => {
            unreachable;
        }
    }
}

//清空表格单元格列表栈、多行表格行缓冲、表格总列数、当前表格单元格类别、上一行表格状态等。
//DEBUG:把.@"单元格"长度清0了。
fn @"Fn表格E"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice("</table>\r\n");
    ptr.*.@"上一行状态"=.@"无后续影响";
    ptr.*.@"表格单元格列表栈".items.len=0;
    ptr.*.@"多行表格行缓冲".@"使用长度"=0;
    ptr.*.@"表格总列数"=0;
    ptr.*.@"当前表格单元格类别"=undefined;
    ptr.*.@"上一行表格状态"=undefined;
}

test "parseline 单行表格" {
    var s=try @"Fn新建状态机"("ab\r#|#-a1 #|b1 #|c1 \n#|a2 #| b2#|^c2 \r#|a3 #|b3#| \r\n#- ll");
    while(!s.@"is输入尾部"){
        try parseline(&s);
    }
    try expectEqualSlices(u8,s.out.items,"<p>ab</p>\r\n<table>\r\n<tr>\r\n<td>#-a1 </td>\r\n<td>b1 </td>\r\n<td>c1 </td>\r\n</tr>\r\n<tr>\r\n<td>a2 </td>\r\n<td> b2</td>\r\n<td class=\"t_center\">c2 </td>\r\n</tr>\r\n<tr>\r\n<td>a3 </td>\r\n<td>b3</td>\r\n<td> </td>\r\n</tr>\r\n</table>\r\n<ul>\r\n<li> ll</li>\r\n");
    @"Fn清空状态机"(&s);
}

test "parseline 多行表格" {
    var s=try @"Fn新建状态机"("#|---\n#|<#--a1#|b1\n#|>#-a2#|#--b2\n#|#-a3#|b3\n#|#--#|b4\n#| #|#--\n#|---\n#|a6#|b6\n#|---\n#|a7#|b7\n#|a8#|b8\n#|---\n#|a9#|b9\nb");
    while(!s.@"is输入尾部"){
        try parseline(&s);
    }
    try expectEqualSlices(u8,s.out.items,"<table>\r\n<tr>\r\n<td class=\"t_left\"><ul>\r\n<li><span>a1</span>\r\n<br /><span>&gt;#-a2</span>\r\n<ul>\r\n<li>a3</li>\r\n</ul>\r\n</li>\r\n</ul>\r\n<br /> </td>\r\n<td>b1<br /><ul>\r\n<li><span>b2</span>\r\n<br /><span>b3</span>\r\n<br /><span>b4</span>\r\n</li>\r\n</ul>\r\n</td>\r\n</tr>\r\n<tr>\r\n<td>a6</td>\r\n<td>b6</td>\r\n</tr>\r\n<tr>\r\n<td>a7<br />a8</td>\r\n<td>b7<br />b8</td>\r\n</tr>\r\n<tr>\r\n<td>a9</td>\r\n<td>b9</td>\r\n</tr>\r\n</table>\r\n<p>b</p>\r\n");
    @"Fn清空状态机"(&s);
}

//style中，@media部分和其它相关内容实现目录在宽屏时在左侧，窄屏时在前面；
//pre 和 code 相关部分实现多行代码行自动加行号；
//table部分设置表格样式和单元格对齐方式。
const htmlhead=
\\<!DOCTYPE html>
\\<html>
\\<head>
\\<meta charset="utf-8">
\\<meta name="viewport" content="width=device-width, initial-scale=1.0">
\\<title></title>
\\<style>
\\:root{
\\    --nav-width: 24em;
\\    --nav-margin-l: 1em;
\\}
\\body{
\\    margin: 0;
\\    line-height: 1.5;
\\}
\\#contents {
\\    max-width: 60em;
\\    margin: auto;
\\    padding: 0 1em;
\\}
\\#navigation {
\\    padding: 0 1em;
\\}
\\@media screen and (min-width: 1025px) {
\\    #navigation {
\\        overflow: auto;
\\        width: var(--nav-width);
\\        height: 100vh;
\\        position: fixed;
\\        top:0;
\\        left:0;
\\        bottom:0;
\\        padding: unset;
\\        margin-left: var(--nav-margin-l);
\\    }
\\    #contents-wrapper {
\\        margin-left: calc(var(--nav-width) + var(--nav-margin-l));
\\    }
\\}
\\table, td {
\\    border-collapse: collapse;
\\    border: 1px solid grey;
\\    text-align:left;
\\    vertical-align:middle;
\\}
\\td {
\\    padding: 0.1em;
\\}
\\.file {
\\    font-weight: bold;
\\    border: unset;
\\}
\\code {
\\    background: #f8f8f8;
\\    border: 1px dotted silver;
\\    padding-left: 0.3em;
\\    padding-right: 0.3em;
\\}
\\pre > code {
\\    display: block;
\\    overflow: auto;
\\    padding: 0.5em;
\\    border: 1px solid #eee;
\\    line-height: normal;
\\}
\\figure {
\\    margin: auto 0;
\\}
\\figure pre {
\\    margin-top: 0;
\\}
\\figcaption {
\\    padding-left: 0.5em;
\\    font-size: small;
\\    border-top-left-radius: 5px;
\\    border-top-right-radius: 5px;
\\}
\\figcaption.zig-cap {
\\    background: #fcdba5;
\\}
\\figcaption.c-cap {
\\    background: #a8b9cc;
\\    color: #000;
\\}
\\figcaption.shell-cap {
\\    background: #ccc;
\\    color: #000;
\\}
\\aside {
\\    border-left: 0.25em solid #f7a41d;
\\    padding: 0 1em 0 1em;
\\}
\\h1 a, h2 a, h3 a, h4 a, h5 a, h6 a {
\\    text-decoration: none;
\\    color: #333;
\\}
\\a.hdr {
\\    visibility: hidden;
\\}
\\h1:hover > a.hdr, h2:hover > a.hdr, h3:hover > a.hdr, h4:hover > a.hdr, h5:hover > a.hdr, h6:hover > a.hdr {
\\    visibility: visible;
\\}
\\pre {
\\    counter-reset: line;
\\}
\\pre .line:before {
\\    counter-increment: line;
\\    content: counter(line);
\\    display: inline-block;
\\    padding-right: 1em;
\\    width: 2em;
\\    text-align: right;
\\    color: #999;
\\}
\\.t_left{
\\    text-align:left;
\\}
\\.t_right{
\\    text-align:right;
\\}
\\.t_center{
\\    text-align:center;
\\}
\\.t_justify{
\\    text-align:justify;
\\}
\\.tv_top{
\\    vertical-align:top;
\\}
\\.tv_middle{
\\    vertical-align:middle;
\\}
\\.tv_bottom{
\\    vertical-align:bottom;
\\}
\\</style>
\\</head>
\\<body>
\\<div id="navigation">
\\
;

//分开htmlhead1和htmlhead，是为了在此记录目录插入位置
const htmlhead1=
\\<div id="contents-wrapper">
\\<main id="contents">
\\
;

const htmlend=
\\</div>
\\</main>
\\</body>
\\</html>
\\
;

fn @"Fn文件头"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.out.appendSlice(htmlhead);
    ptr.*.@"插入目录位置"=ptr.*.out.items.len;
    try ptr.*.out.appendSlice(htmlhead1);
}

fn @"Fn文件尾"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try ptr.*.@"目录".appendSlice("</ul>\r\n</div>\r\n");
    try ptr.*.out.insertSlice(ptr.*.@"插入目录位置",ptr.*.@"目录".items);
    try ptr.*.out.appendSlice(htmlend);
}

fn @"Fn文件结尾状态处理"(ptr:*@"Tprogdoc格式转换状态机") !void{
    switch(ptr.*.@"上一行状态"){
        .@"多行代码行C" => {
            return progdoc_err.@"多行代码没有结束行";
        },
        .@"内嵌html多行C" => {
            return progdoc_err.@"内嵌html多行没有结束行";
        },
        .@"列表C" => {
            try @"Fn列表E"(ptr);
        },
        .@"表格C" => {
            try @"Fn表格E"(ptr);
        },
        .@"无后续影响" => {},
    }
}

fn @"Fn解析progdoc"(ptr:*@"Tprogdoc格式转换状态机") !void{
    try @"Fn文件头"(ptr);
    while(!ptr.*.@"is输入尾部"){
        try parseline(ptr); 
    }
    try @"Fn文件结尾状态处理"(ptr);
    try @"Fn文件尾"(ptr);
}

//因人工编写的program doc的文本文件一般情况下不可能太大，所以设置最大输入文件长度为100M。
const @"最大输入文件长度"=0x10_0000 * 100; //100M

//调用方式
pub fn main() !void{
    const args = try process.argsAlloc(al); //获取命令行参数，第0个是可执行程序本身
    if(args.len!=2){
        print("not input file, please input:\r\nprogdoc example.pd\r\n",.{});
        return;
    }

    //获取不包含后缀的文件名
    var iend:usize=0;
    _=@"Fn当前行查找字符"(args[1],0,'.',&iend);
    const fname=args[1][0..iend];

    //打开输入文件名，并一次性读入到内存
    var home=std.fs.cwd();
    defer home.close();
    var infile=try home.openFile(args[1],.{});
    defer infile.close();
    const in=try infile.readToEndAlloc(al,@"最大输入文件长度");

    //解析生成html
    var s=try @"Fn新建状态机"(in);
    try @"Fn解析progdoc"(&s);
    al.free(in);

    //生成输出文件名
    var outfname=try std.ArrayList(u8).initCapacity(al,80);
    defer outfname.deinit();
    try outfname.appendSlice(fname);
    try outfname.appendSlice(".html");

    //创建输出文件，并一次性写入解析结果
    var outfile=try home.createFile(outfname.items,.{});
    defer outfile.close();

    try outfile.writeAll(s.out.items);

    //@"Fn清空状态机"(&s);
    //arena.deinit(); 
    //两次释放内存未定义行为是在多行表格行的处理上，但才疏学浅，死活找不出原因。
    //反正这个小工具用完了就退出，目前看还不影响正常使用，就退出不清理内存了，先不管了。
}





