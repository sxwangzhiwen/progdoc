# progdoc
progdoc是一种简易文档格式，主要用于编写程序设计和软件开发相关文档。

一、解析程序
可在主页的release处下载windows环境的可执行程序。
也可下载 progdoc.zig 源代码后，执行：
$ zig build-exe progdoc.zig
生成可执行程序。

二、使用方法
xxx是progdoc格式的UTF-8编码的文本文件，通常文件名后缀是 .pd 。
$ progdoc xxx
在同一目录下，生成同名的单一的 .html 文件。


三、progdoc文档格式说明
参看[progdoc文档格式](https://github.com/)

四、无英文说明
因本人英文太差，所以以中文为主，不提供英文版本。
