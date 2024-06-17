import{u as n,j as s}from"./index-DSR5mI-m.js";const a={title:"zig-aio: io_uring like asynchronous API and coroutine powered IO tasks for zig",description:"undefined"};function r(l){const i={a:"a",code:"code",div:"div",h1:"h1",h2:"h2",header:"header",li:"li",p:"p",pre:"pre",span:"span",ul:"ul",...n(),...l.components};return s.jsxs(s.Fragment,{children:[s.jsx(i.header,{children:s.jsxs(i.h1,{id:"overview",children:["Overview",s.jsx(i.a,{"aria-hidden":"true",tabIndex:"-1",href:"#overview",children:s.jsx(i.div,{"data-autolink-icon":!0})})]})}),`
`,s.jsx(i.p,{children:"zig-aio provides io_uring like asynchronous API and coroutine powered IO tasks for zig"}),`
`,s.jsx(i.pre,{className:"shiki shiki-themes github-light github-dark-dimmed",style:{backgroundColor:"#fff","--shiki-dark-bg":"#22272e",color:"#24292e","--shiki-dark":"#adbac7"},tabIndex:"0",children:s.jsxs(i.code,{children:[s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"const"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" std"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:" @import"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"std"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:");"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"const"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" aio"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:" @import"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"aio"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:");"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"const"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" log"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" std"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"log"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"scoped"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"(."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"aio_static"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:");"})]}),`
`,s.jsx(i.span,{className:"line","data-empty-line":!0,children:" "}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"pub"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" fn"}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:" main"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"() "}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"!void"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:" {"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" try"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" std"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"fs"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"cwd"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"()."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"openFile"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"flake.nix"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:", .{});"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    defer"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"close"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"();"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" buf"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:": ["}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:"4096"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"]"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"u8"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" undefined"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:";"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" len"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:": "}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"usize"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:" 0"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:";"})]}),`
`,s.jsx(i.span,{className:"line","data-empty-line":!0,children:" "}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f2"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" try"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" std"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"fs"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"cwd"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"()."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"openFile"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"build.zig.zon"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:", .{});"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    defer"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"close"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"();"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" buf2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:": ["}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:"4096"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"]"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"u8"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" undefined"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:";"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    var"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" len2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:": "}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"usize"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:" 0"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:";"})]}),`
`,s.jsx(i.span,{className:"line","data-empty-line":!0,children:" "}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"    const"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" ret"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" try"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" aio"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"batch"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"(.{"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"        aio"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"Read"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"{"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"file"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buffer"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" &"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buf"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"out_read"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" &"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"len"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsx(i.span,{className:"line",children:s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"        },"})}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"        aio"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"Read"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"{"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"file"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" f2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buffer"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" &"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buf2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"            ."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"out_read"}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" ="}),s.jsx(i.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" &"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"len2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:","})]}),`
`,s.jsx(i.span,{className:"line",children:s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"        },"})}),`
`,s.jsx(i.span,{className:"line",children:s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"    });"})}),`
`,s.jsx(i.span,{className:"line","data-empty-line":!0,children:" "}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"    log"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"info"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"{s}"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:", .{"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buf"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"["}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:"0"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:".."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"len"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"]});"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"    log"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"info"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"{s}"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:", .{"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"buf2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"["}),s.jsx(i.span,{style:{color:"#005CC5","--shiki-dark":"#6CB6FF"},children:"0"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:".."}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"len2"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"]});"})]}),`
`,s.jsxs(i.span,{className:"line",children:[s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"    log"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),s.jsx(i.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"info"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),s.jsx(i.span,{style:{color:"#032F62","--shiki-dark":"#96D0FF"},children:'"{}"'}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:", .{"}),s.jsx(i.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"ret"}),s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"});"})]}),`
`,s.jsx(i.span,{className:"line",children:s.jsx(i.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"}"})})]})}),`
`,s.jsxs(i.h2,{id:"features",children:["Features",s.jsx(i.a,{"aria-hidden":"true",tabIndex:"-1",href:"#features",children:s.jsx(i.div,{"data-autolink-icon":!0})})]}),`
`,s.jsxs(i.ul,{children:[`
`,s.jsx(i.li,{children:"Blocking and asynchronous API"}),`
`,s.jsx(i.li,{children:"Atomic operations"}),`
`,s.jsx(i.li,{children:"Parallel execution"}),`
`,s.jsx(i.li,{children:"Cancellation"}),`
`,s.jsx(i.li,{children:"Timeouts"}),`
`,s.jsx(i.li,{children:"Comes with a runtime and scheduler for coroutines"}),`
`,s.jsx(i.li,{children:"Tightly tied into io_uring"}),`
`]})]})}function c(l={}){const{wrapper:i}={...n(),...l.components};return i?s.jsx(i,{...l,children:s.jsx(r,{...l})}):r(l)}export{c as default,a as frontmatter};
