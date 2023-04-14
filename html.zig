//style中，@media部分和其它相关内容实现目录在宽屏时在左侧，窄屏时在前面；
//pre 和 code 相关部分实现多行代码行自动加行号；
//table部分设置表格样式和单元格对齐方式。

pub const htmlhead =
    \\ <!DOCTYPE html>
    \\ <html>
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
pub const htmlhead1 =
    \\<div id="contents-wrapper">
    \\<main id="contents">
    \\
;

pub const htmlend =
    \\</div>
    \\</main>
    \\</body>
    \\</html>
    \\
;

pub const style = 
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
    ;
