import{u as r,j as e}from"./index-Ck8oy7AW.js";const t={title:"CORO API",description:"undefined"};function n(i){const s={a:"a",code:"code",div:"div",h1:"h1",h2:"h2",header:"header",p:"p",pre:"pre",span:"span",...r(),...i.components};return e.jsxs(e.Fragment,{children:[e.jsx(s.header,{children:e.jsxs(s.h1,{id:"coro-api",children:["CORO API",e.jsx(s.a,{"aria-hidden":"true",tabIndex:"-1",href:"#coro-api",children:e.jsx(s.div,{"data-autolink-icon":!0})})]})}),`
`,e.jsxs(s.h2,{id:"paired-context-switches",children:["Paired context switches",e.jsx(s.a,{"aria-hidden":"true",tabIndex:"-1",href:"#paired-context-switches",children:e.jsx(s.div,{"data-autolink-icon":!0})})]}),`
`,e.jsxs(s.p,{children:[`To yield running task to the caller use the following.
The function takes a enum value as a argument representing the yield state of the task.
Enum value that corresponds to the integer `,e.jsx(s.code,{children:"0"})," is resevered to indicate non yield state."]}),`
`,e.jsx(s.pre,{className:"shiki shiki-themes github-light github-dark-dimmed",style:{backgroundColor:"#fff","--shiki-dark-bg":"#22272e",color:"#24292e","--shiki-dark":"#adbac7"},tabIndex:"0",children:e.jsx(s.code,{children:e.jsxs(s.span,{className:"line",children:[e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"coro"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),e.jsx(s.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"yield"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"SomeEnum"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"value"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:");"})]})})}),`
`,e.jsxs(s.p,{children:["The current yield state of a task can be checked with ",e.jsx(s.code,{children:"state"}),` method.
To wakeup a task use the `,e.jsx(s.code,{children:"wakeup"})," method. When task is woken up the yield state is reset to ",e.jsx(s.code,{children:"0"}),`.
Calling `,e.jsx(s.code,{children:"wakeup"})," when the task isn't yielded by application's yield state is a error."]}),`
`,e.jsx(s.p,{children:"Example of checking the current yield state and then waking up the task."}),`
`,e.jsx(s.pre,{className:"shiki shiki-themes github-light github-dark-dimmed",style:{backgroundColor:"#fff","--shiki-dark-bg":"#22272e",color:"#24292e","--shiki-dark":"#adbac7"},tabIndex:"0",children:e.jsxs(s.code,{children:[e.jsxs(s.span,{className:"line",children:[e.jsx(s.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:"switch"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:" ("}),e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"task"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),e.jsx(s.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"state"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"("}),e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"SomeEnum"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:")) {"})]}),`
`,e.jsxs(s.span,{className:"line",children:[e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:"    value"}),e.jsx(s.span,{style:{color:"#D73A49","--shiki-dark":"#F47067"},children:" =>"}),e.jsx(s.span,{style:{color:"#E36209","--shiki-dark":"#F69D50"},children:" task"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"."}),e.jsx(s.span,{style:{color:"#6F42C1","--shiki-dark":"#DCBDFB"},children:"wakeup"}),e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"(),"})]}),`
`,e.jsx(s.span,{className:"line",children:e.jsx(s.span,{style:{color:"#24292E","--shiki-dark":"#ADBAC7"},children:"}"})})]})})]})}function d(i={}){const{wrapper:s}={...r(),...i.components};return s?e.jsx(s,{...i,children:e.jsx(n,{...i})}):n(i)}export{d as default,t as frontmatter};
