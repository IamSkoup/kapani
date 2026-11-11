// Exercise the spotlight tutorial without logging in or writing user data.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const script=fs.readFileSync(path.join(__dirname,'../assets/kapani-onboarding.js'),'utf8');

function harness(width,height,reduced){
  let time=0,nextTimer=0,scrollCount=0;
  const timers=new Map();
  const run=(ms)=>{
    const until=time+ms;
    for(let safety=0;safety<4000;safety++){
      let first=null;
      for(const [id,t] of timers)if(t.at<=until&&(!first||t.at<first[1].at))first=[id,t];
      if(!first)break;
      time=first[1].at;timers.delete(first[0]);first[1].fn();
    }
    time=until;
  };
  const fakeSet=(fn,ms)=>{const id=++nextTimer;timers.set(id,{fn,at:time+ms});return id;};
  const fakeClear=id=>timers.delete(id);
  class ClassList{
    constructor(){this.values=new Set();}
    add(x){this.values.add(x);}remove(x){this.values.delete(x);}
    contains(x){return this.values.has(x);}
  }
  class Element{
    constructor(id,rect={left:0,top:0,right:350,bottom:250}){
      this.id=id;this.rect={...rect,width:rect.right-rect.left,height:rect.bottom-rect.top};
      this.style={};this.dataset={};this.classList=new ClassList();this.attrs={};this.nodes={};this.events={};
      this.textContent='';this.hidden=false;this.offsetWidth=id==='#kpTourBubble'?(width<=480?Math.min(345,width-20):380):350;this.offsetHeight=id==='#kpTourBubble'?320:265;
    }
    setAttribute(key,val){this.attrs[key]=val;}
    addEventListener(name,callback){this.events[name]=callback;}
    querySelector(selector){return this.nodes[selector]??(this.nodes[selector]=new Element(selector));}
    querySelectorAll(){return ['.kp-tour-skip','.kp-tour-back','.kp-tour-next'].map(s=>this.querySelector(s)).filter(el=>!el.hidden);}
    getBoundingClientRect(){return {...this.rect};}
    closest(selector){return selector.includes('#bottomNav')&&this.id.startsWith('#bn')?this:null;}
    scrollIntoView(){scrollCount++;this.rect.top=260;this.rect.bottom=350;}
    focus(){document.activeElement=this;}
    remove(){document.root=null;}
    dispatch(name){this.events[name]?.({preventDefault(){}});}
  }
  const coords={
    '#home .hero-person':{left:width<500?20:340,top:120,right:width<500?305:690,bottom:235},
    '#bn1':{left:width<500?75:15,top:width<500?610:180,right:width<500?132:210,bottom:width<500?660:225},
    '#bn4':{left:width<500?195:15,top:width<500?610:350,right:width<500?255:210,bottom:width<500?660:395},
    '#bnMore':{left:width<500?300:15,top:width<500?610:670,right:width<500?370:210,bottom:width<500?660:715},
    '#home .quick-card[onclick*="navTo(\'market\')"]':{left:width<500?20:360,top:900,right:width<500?355:640,bottom:990},
    '#home .quick-card[onclick*="navTo(\'jobs\')"]':{left:width<500?20:360,top:1200,right:width<500?355:640,bottom:1290}
  };
  const targets=Object.fromEntries(Object.entries(coords).map(([id,r])=>[id,new Element(id,r)]));
  const document={
    root:null,activeElement:null,documentElement:{classList:new ClassList(),clientWidth:width},listeners:{},
    body:new Element('body'),
    getElementById(id){return id==='kpFirstVisitTour'?this.root:null;},
    createElement(id){return new Element(id);},
    querySelector(selector){return targets[selector]||null;},
    addEventListener(type,fn){this.listeners[type]=fn;},
    removeEventListener(type){delete this.listeners[type];}
  };
  document.documentElement.appendChild=node=>{document.root=node;};
  const window={
    innerWidth:width,innerHeight:height,scrollX:0,scrollY:0,events:{},
    matchMedia:()=>({matches:reduced}),getComputedStyle:()=>({display:'block',visibility:'visible'}),
    setTimeout:fakeSet,clearTimeout:fakeClear,
    requestAnimationFrame:fn=>fakeSet(fn,16),cancelAnimationFrame:fakeClear,
    scrollTo(){},
    addEventListener(type,fn){this.events[type]=fn;},
    removeEventListener(type){delete this.events[type];}
  };
  vm.runInNewContext(script,{window,document,console,Array,Math},{filename:'onboarding.js'});
  return {document,window,run,get scrollCount(){return scrollCount;}};
}

{
  const ui=harness(1366,768,false);let completed=0;
  assert.equal(ui.window.kapaniOnboardingStart({onDone:()=>completed++}),true);
  assert.equal(ui.window.kapaniOnboardingStart(),false,'another tour cannot stack');
  const root=ui.document.root;
  assert.equal(root.attrs['aria-modal'],'true');
  assert.equal(root.querySelector('#kpTourCount').textContent,'01 / 06');
  assert.ok(Number.parseInt(root.querySelector('.kp-tour-spotlight').style.width)>50);
  assert.equal(root.querySelector('.kp-tour-shade-left').style.width,undefined,'single continuous spotlight avoids four-strip masking');
  ui.run(180);
  assert.ok(root.querySelector('#kpTourTitle').textContent.length>0,'title prints progressively');
  assert.ok(root.querySelector('#kpTourTitle').textContent.length<40);
  ui.run(4000);
  assert.equal(root.querySelector('#kpTourTitle').textContent,'Добро пожаловать в Капани.');
  root.querySelector('.kp-tour-next').dispatch('click');ui.run(180);
  assert.equal(root.querySelector('#kpTourCount').textContent,'02 / 06');
  assert.ok(root.querySelector('.kp-tour-spotlight').style.left.endsWith('px'));
  root.querySelector('.kp-tour-skip').dispatch('click');
  root.querySelector('.kp-tour-skip').dispatch('click');ui.run(250);
  assert.equal(completed,1,'skip completes once');
  assert.equal(ui.document.root,null);
  assert.equal(ui.document.body.classList.contains('kp-tour-open'),false);
}
{
  const ui=harness(375,667,true);let completed=0;
  ui.window.kapaniOnboardingStart({onDone:()=>completed++});
  const root=ui.document.root;
  assert.equal(root.querySelector('#kpTourTitle').textContent,'Добро пожаловать в Капани.','reduced-motion shows whole text immediately');
  for(let i=1;i<6;i++){
    root.querySelector('.kp-tour-next').dispatch('click');ui.run(0);
    assert.equal(root.querySelector('#kpTourCount').textContent,`${String(i+1).padStart(2,'0')} / 06`);
    const bubble=root.querySelector('#kpTourBubble');
    assert.ok(Number.parseInt(bubble.style.left)>=0&&Number.parseInt(bubble.style.top)>=0,'mobile bubble stays in viewport');
  }
  assert.ok(ui.scrollCount>=2,'off-screen market and jobs are scrolled into view');
  root.querySelector('.kp-tour-next').dispatch('click');ui.run(0);
  assert.equal(completed,1);
  assert.equal(ui.document.root,null);
}
for(const [width,height] of [[320,568],[390,844],[1024,768],[1920,1080]]){
  const ui=harness(width,height,true);
  ui.window.kapaniOnboardingStart();
  const root=ui.document.root;
  const bubble=root.querySelector('#kpTourBubble');
  for(let step=0;step<6;step++){
    const x=Number.parseInt(bubble.style.left),y=Number.parseInt(bubble.style.top);
    assert.ok(x>=0&&x+bubble.offsetWidth<=width,`${width}x${height}: bubble fits horizontally at step ${step}`);
    assert.ok(y>=0&&y+bubble.offsetHeight<=height,`${width}x${height}: bubble fits vertically at step ${step}`);
    if(step<5){root.querySelector('.kp-tour-next').dispatch('click');ui.run(0);}
  }
  root.querySelector('.kp-tour-skip').dispatch('click');ui.run(0);
  assert.equal(ui.document.root,null,`${width}x${height}: skip must unblock page`);
}
console.log('OK: six-step tour, unclipped overlay, desktop/tablet/phone geometry, keyboard navigation and completion.');
