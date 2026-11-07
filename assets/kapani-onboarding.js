/* First registration: a guided look at the real page. No data writes here. */
(function () {
  'use strict';

  const steps = [
    { label:'Здесь ты дома', title:'Добро пожаловать в Капани.',
      description:'Это сайт нашего посёлка. Здесь можно общаться, покупать, работать и узнавать, что происходит вокруг. Сейчас быстро покажу, где что лежит.',
      targets:['#home .hero-person','#home .home-hero'] },
    { label:'Свои люди', title:'Начни с общения.',
      description:'В «Чатах» есть общий разговор и личные сообщения. Новости рассказывают, что нового в посёлке, а у каждого жителя есть свой профиль.',
      targets:['#bn1','#bnMore','#gHeader .header-links'] },
    { label:'Покупки и поездки', title:'Всё нужное под рукой.',
      description:'В К-маркете продают вещи и услуги. Рядом можно вызвать такси или заказать доставку. Просто выбери нужный раздел на главной.',
      targets:["#home .quick-card[onclick*=\"navTo('market')\"]",'#home .service-group:first-child .quick-card','#home .service-catalog'] },
    { label:'Капанёвские рубли', title:'Здесь есть свой банк.',
      description:'На банковском счёте лежат виртуальные рубли. Ими можно рассчитываться, переводить деньги другим жителям и пополнять накопительный счёт.',
      targets:['#bn4','#gHeader .h-bal','#home .home-hero .stats-row'] },
    { label:'Дела посёлка', title:'Хочешь заработать?',
      description:'Открывай «Работу» и выбирай вакансию. Есть задания, обучение, экзамен КВЭ и своё дело. Должности и рабочие панели выдаются по правилам посёлка.',
      targets:["#home .quick-card[onclick*=\"navTo('jobs')\"]",'#home .service-group:nth-child(2)','#bnMore'] },
    { label:'На этом всё', title:'Дальше разберёшься сам.',
      description:'Остальные места — в «Разделах»: больница, мероприятия, мэрия, здания и многое другое. А свои данные и настройки найдёшь в профиле. Приятного пользования!',
      targets:['#bnMore','#bn7','#gHeader .header-actions'] }
  ];

  const clamp = (n,lo,hi) => Math.max(lo,Math.min(hi,n));
  window.kapaniOnboardingStart = function ({onDone} = {}) {
    if(document.getElementById('kpFirstVisitTour')) return false;
    const reduced = Boolean(window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || document.documentElement.classList.contains('v8-reduce-motion'));
    const oldFocus = document.activeElement;
    const oldScroll = {x:window.scrollX||0,y:window.scrollY||0};
    let index=0,changing=false,finishing=false,target=null,typing=0,scrollJob=0,frame=0;

    const root=document.createElement('div');
    root.id='kpFirstVisitTour';root.className='kp-tour-overlay';
    root.setAttribute('role','dialog');root.setAttribute('aria-modal','true');root.setAttribute('aria-labelledby','kpTourTitle');
    root.innerHTML=`<div class="kp-tour-shade kp-tour-shade-top" aria-hidden="true"></div>
      <div class="kp-tour-shade kp-tour-shade-left" aria-hidden="true"></div>
      <div class="kp-tour-shade kp-tour-shade-right" aria-hidden="true"></div>
      <div class="kp-tour-shade kp-tour-shade-bottom" aria-hidden="true"></div>
      <div class="kp-tour-spotlight" aria-hidden="true"></div>
      <section class="kp-tour-bubble" id="kpTourBubble">
        <div class="kp-tour-top"><span class="kp-tour-brand">Капани <span class="kp-tour-brand-dot"></span> знакомство</span><button class="kp-tour-skip" type="button">Пропустить</button></div>
        <div class="kp-tour-content"><span class="kp-tour-label" id="kpTourLabel"></span>
          <div class="kp-tour-type-title"><span class="kp-tour-type-spacer" id="kpTourTitleSize" aria-hidden="true"></span><h2 id="kpTourTitle"></h2></div>
          <div class="kp-tour-type-description"><span class="kp-tour-type-spacer" id="kpTourDescriptionSize" aria-hidden="true"></span><p id="kpTourDescription"></p></div></div>
        <div class="kp-tour-bottom"><div class="kp-tour-progress"><span id="kpTourCount"></span><div class="kp-tour-track"><span id="kpTourFill"></span></div></div>
          <div class="kp-tour-controls"><button type="button" class="kp-tour-back">Назад</button><button type="button" class="kp-tour-next">Дальше</button></div></div>
      </section>`;
    const find=sel=>root.querySelector(sel),bubble=find('#kpTourBubble'),spot=find('.kp-tour-spotlight');
    const title=find('#kpTourTitle'),copy=find('#kpTourDescription');
    const back=find('.kp-tour-back'),next=find('.kp-tour-next'),skip=find('.kp-tour-skip');
    const shades=['top','left','right','bottom'].map(side=>find('.kp-tour-shade-'+side));
    const wait=(ms,fn)=>window.setTimeout(fn,ms);

    function stopTyping(){if(typing)window.clearTimeout(typing);typing=0;bubble.classList.remove('kp-tour-typing');}
    function typeText(step){
      stopTyping();title.textContent='';copy.textContent='';title.setAttribute('aria-label',step.title);copy.setAttribute('aria-label',step.description);
      if(reduced){title.textContent=step.title;copy.textContent=step.description;return;}
      const heading=Array.from(step.title),body=Array.from(step.description);let position=0;
      bubble.classList.add('kp-tour-typing');
      const tick=()=>{
        if(finishing||changing)return;
        position++;
        title.textContent=heading.slice(0,Math.min(position,heading.length)).join('');
        if(position>heading.length)copy.textContent=body.slice(0,position-heading.length).join('');
        if(position<heading.length+body.length)typing=wait(23,tick);else stopTyping();
      };
      typing=wait(110,tick);
    }
    function isVisible(el){
      if(!el)return false;const r=el.getBoundingClientRect(),style=window.getComputedStyle?.(el);
      return r.width>0&&r.height>0&&style?.display!=='none'&&style?.visibility!=='hidden';
    }
    function findTarget(step){
      for(const sel of step.targets){const el=document.querySelector(sel);if(isVisible(el))return el;}
      return document.querySelector('#home .hero-person')||document.querySelector('#gHeader');
    }
    function place(el,x,y,w,h){
      el.style.left=Math.round(x)+'px';el.style.top=Math.round(y)+'px';
      el.style.width=Math.max(0,Math.round(w))+'px';el.style.height=Math.max(0,Math.round(h))+'px';
    }
    function layout(){
      if(finishing)return;
      const vw=window.innerWidth,vh=window.innerHeight,pad=vw<480?6:9;
      const rect=target?.getBoundingClientRect();
      const l=clamp((rect?.left??24)-pad,5,vw-30),t=clamp((rect?.top??70)-pad,5,vh-30);
      const r=clamp((rect?.right??150)+pad,l+20,vw-5),b=clamp((rect?.bottom??120)+pad,t+20,vh-5);
      place(spot,l,t,r-l,b-t);place(shades[0],0,0,vw,t);place(shades[1],0,t,l,b-t);
      place(shades[2],r,t,vw-r,b-t);place(shades[3],0,b,vw,vh-b);
      const margin=vw<480?10:16,gap=vw<480?15:22,w=bubble.offsetWidth,h=bubble.offsetHeight;
      const options=[
        {side:'right',x:r+gap,y:(t+b-h)/2,fits:r+gap+w<=vw-margin},
        {side:'left',x:l-w-gap,y:(t+b-h)/2,fits:l-w-gap>=margin},
        {side:'bottom',x:(l+r-w)/2,y:b+gap,fits:b+gap+h<=vh-margin},
        {side:'top',x:(l+r-w)/2,y:t-h-gap,fits:t-h-gap>=margin}
      ];
      const order=(vw>=790&&r<vw*.4)?[0,2,3,1]:[2,3,0,1];
      const preferred=order.map(i=>options[i]).find(o=>o.fits);
      // If no side is tall enough on a small phone, choose the least-obscuring spot.
      const overlap=o=>{
        const x=clamp(o.x,margin,Math.max(margin,vw-w-margin)),y=clamp(o.y,margin,Math.max(margin,vh-h-margin));
        return Math.max(0,Math.min(x+w,r)-Math.max(x,l))*Math.max(0,Math.min(y+h,b)-Math.max(y,t));
      };
      const position=preferred||options.sort((a,b)=>overlap(a)-overlap(b))[0];
      bubble.style.left=Math.round(clamp(position.x,margin,Math.max(margin,vw-w-margin)))+'px';
      bubble.style.top=Math.round(clamp(position.y,margin,Math.max(margin,vh-h-margin)))+'px';
      bubble.dataset.side=position.side;
    }
    function scheduleLayout(){if(frame)return;frame=window.requestAnimationFrame(()=>{frame=0;layout();});}
    function render(){
      const step=steps[index];target=findTarget(step);
      find('#kpTourLabel').textContent=step.label;
      find('#kpTourTitleSize').textContent=step.title;find('#kpTourDescriptionSize').textContent=step.description;
      find('#kpTourCount').textContent=`${String(index+1).padStart(2,'0')} / ${String(steps.length).padStart(2,'0')}`;
      find('#kpTourFill').style.width=((index+1)/steps.length*100)+'%';
      back.hidden=index===0;next.textContent=index===steps.length-1?'Закончить':'Дальше';
      next.setAttribute('aria-label',index===steps.length-1?'Завершить знакомство':'Следующий шаг');
      typeText(step);layout();
      if(target&&!target.closest('#bottomNav, #gHeader')){
        const rect=target.getBoundingClientRect();
        if((rect.bottom>window.innerHeight-90||rect.top<75)&&typeof target.scrollIntoView==='function'){
          target.scrollIntoView({behavior:reduced?'instant':'smooth',block:'center',inline:'nearest'});
          window.clearTimeout(scrollJob);scrollJob=wait(reduced?0:390,layout);
        }
      }
    }
    function move(delta){
      if(finishing||changing)return;const dest=index+delta;if(dest<0)return;if(dest>=steps.length){finish();return;}
      changing=true;stopTyping();bubble.classList.add('kp-tour-changing');
      wait(reduced?0:170,()=>{if(finishing)return;index=dest;changing=false;render();bubble.classList.remove('kp-tour-changing');});
    }
    function finish(){
      if(finishing)return;finishing=true;stopTyping();window.clearTimeout(scrollJob);
      if(frame)window.cancelAnimationFrame(frame);root.classList.add('kp-tour-closing');
      wait(reduced?0:230,()=>{
        window.removeEventListener('resize',scheduleLayout);window.removeEventListener('scroll',scheduleLayout,true);
        document.removeEventListener('keydown',onKeydown,true);root.remove();document.body.classList.remove('kp-tour-open');
        try{window.scrollTo({left:oldScroll.x,top:oldScroll.y,behavior:'instant'});}catch(_){}
        try{oldFocus?.focus?.({preventScroll:true});}catch(_){}
        try{onDone?.();}catch(error){console.error('[Kapani onboarding] completion:',error);}
      });
    }
    function onKeydown(e){
      if(e.key==='Escape'){e.preventDefault();finish();return;}
      if(e.key==='ArrowRight'){e.preventDefault();move(1);return;}
      if(e.key==='ArrowLeft'){e.preventDefault();move(-1);return;}
      if(e.key!=='Tab')return;
      const controls=[...root.querySelectorAll('button:not([hidden]):not([disabled])')];
      if(!controls.length)return;const first=controls[0],last=controls[controls.length-1];
      if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}
      else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}
    }
    skip.addEventListener('click',finish);back.addEventListener('click',()=>move(-1));next.addEventListener('click',()=>move(1));
    document.body.appendChild(root);document.body.classList.add('kp-tour-open');
    document.addEventListener('keydown',onKeydown,true);window.addEventListener('resize',scheduleLayout);window.addEventListener('scroll',scheduleLayout,true);
    render();next.focus({preventScroll:true});return true;
  };
})();
