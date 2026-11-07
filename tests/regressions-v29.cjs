// First-registration tour: source contracts plus a small DOM lifecycle harness.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootPath = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(rootPath, name), 'utf8');
const html = read('index.html');
const main = read('assets/kapani-main-classic.js');
const tour = read('assets/kapani-onboarding.js');
const css = read('assets/kapani-onboarding.css');
const sw = read('firebase-messaging-sw.js');

assert.match(html, /kapani-onboarding\.js\?v=29/);
assert.match(html, /kapani-onboarding\.css\?v=29/);
assert.ok(html.indexOf('kapani-onboarding.js?v=29') < html.indexOf('kapani-main-classic.js?v=30'));
assert.match(main, /firstVisitTour:\s*\{\s*version:\s*1,\s*completed:\s*false/);
assert.match(main, /await update\(userRef\(nick\),\s*\{settings:/);
assert.match(main, /function needsFirstVisitTour\(profile\)/);
assert.match(main, /serverState\?\.completed === true/);
assert.match(main, /function finishFirstVisitTour\(nick\)/);
assert.match(main, /setTimeout\(\(\) => showFirstPushPrompt\(\), 420\)/);
assert.match(main, /if\(qs\('kpFirstVisitTour'\)\) return/);
assert.match(sw, /kapani-static-v(?:29|30)/);
assert.match(css, /prefers-reduced-motion/);
assert.match(css, /@media \(max-width: 680px\)/);
assert.equal((tour.match(/label: '/g) || []).length, 5);

class ClassList {
    constructor() { this.values = new Set(); }
    add(name) { this.values.add(name); }
    remove(name) { this.values.delete(name); }
    contains(name) { return this.values.has(name); }
}
class Element {
    constructor(document, tag='div') {
        this.ownerDocument=document; this.tagName=tag; this.classList=new ClassList();
        this.style={}; this.attrs={}; this.events={}; this.nodes={};
        this.removed=false; this.hidden=false; this.textContent='';
    }
    setAttribute(name, value) { this.attrs[name]=value; }
    addEventListener(name, callback) { this.events[name]=callback; }
    querySelector(selector) {
        if(!this.nodes[selector]) this.nodes[selector]=new Element(this.ownerDocument, 'button');
        return this.nodes[selector];
    }
    querySelectorAll() {
        return ['.kp-tour-skip','.kp-tour-back','.kp-tour-next']
            .map(s=>this.querySelector(s)).filter(el=>!el.hidden);
    }
    focus() { this.ownerDocument.activeElement=this; }
    remove() { this.removed=true; this.ownerDocument.root=null; }
    dispatch(name) { this.events[name]?.({preventDefault(){}}); }
}

const doc = {
    activeElement: null,
    documentElement: {classList:new ClassList()},
    listeners: {}, root: null,
    getElementById(id) { return id==='kpFirstVisitTour' ? this.root : null; },
    createElement(tag) { return new Element(this, tag); },
    addEventListener(name, cb) { this.listeners[name]=cb; },
    removeEventListener(name) { delete this.listeners[name]; }
};
doc.body = new Element(doc, 'body');
doc.body.classList=new ClassList();
doc.body.appendChild = node => { doc.root=node; };
const browser = {matchMedia:()=>({matches:false}),setTimeout};
vm.runInNewContext(tour, {window:browser,document:doc,console,setTimeout}, {filename:'kapani-onboarding.js'});
const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));

(async()=>{
    let completed=0;
    assert.equal(browser.kapaniOnboardingStart({onDone:()=>{completed++;}}),true);
    assert.equal(browser.kapaniOnboardingStart(),false,'the tour must not stack');
    const dialog=doc.root;
    assert.equal(dialog.attrs['aria-modal'],'true');
    assert.match(dialog.querySelector('#kpTourTitle').textContent,/Капани/);
    assert.equal(dialog.querySelector('#kpTourCount').textContent,'01 / 05');
    assert.equal(dialog.querySelector('.kp-tour-back').hidden,true);
    dialog.querySelector('.kp-tour-next').dispatch('click');
    await pause(375);
    assert.equal(dialog.querySelector('#kpTourCount').textContent,'02 / 05');
    assert.equal(dialog.querySelector('.kp-tour-back').hidden,false);
    assert.match(dialog.querySelector('#kpTourDescription').textContent,/Чатах/);
    dialog.querySelector('.kp-tour-back').dispatch('click');
    await pause(375);
    assert.equal(dialog.querySelector('#kpTourCount').textContent,'01 / 05');
    dialog.querySelector('.kp-tour-skip').dispatch('click');
    dialog.querySelector('.kp-tour-skip').dispatch('click');
    await pause(270);
    assert.equal(completed,1,'skip must finish exactly once');
    assert.equal(doc.root,null);
    assert.equal(doc.body.classList.contains('kp-tour-open'),false);
    console.log('OK: revision 29 first-visit tour navigation, skip, replay guard, notification sequencing and mobile/reduced-motion styles.');
})().catch(error=>{console.error(error);process.exitCode=1;});
