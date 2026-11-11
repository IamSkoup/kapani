// The registration-to-tour handoff stays intact after replacing the card tour.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=name=>fs.readFileSync(path.join(root,name),'utf8');
const html=read('index.html');
const main=read('assets/kapani-main-classic.js');
const tour=read('assets/kapani-onboarding.js');
const css=read('assets/kapani-onboarding.css');
const sw=read('firebase-messaging-sw.js');

assert.match(html,/kapani-onboarding\.js\?v=38/);
assert.match(html,/kapani-onboarding\.css\?v=38/);
assert.ok(html.indexOf('kapani-onboarding.js?v=38')<html.indexOf('kapani-main-classic.js?v=38'));
assert.match(main,/firstVisitTour:\s*\{\s*version:\s*1,\s*completed:\s*false/);
assert.match(main,/await update\(userRef\(nick\),\s*\{settings:/);
assert.match(main,/function needsFirstVisitTour\(profile\)/);
assert.match(main,/serverState\?\.completed === true/);
assert.match(main,/function finishFirstVisitTour\(nick\)/);
assert.match(main,/setTimeout\(\(\) => showFirstPushPrompt\(\), 420\)/);
assert.match(main,/if\(qs\('kpFirstVisitTour'\)\) return/);
assert.match(sw,/kapani-static-v38/);
assert.match(sw,/kapani-onboarding\.js\?v=38/);
assert.match(tour,/window\.kapaniOnboardingStart/);
assert.match(tour,/kp-tour-shade-top/);
assert.match(tour,/kp-tour-spotlight/);
assert.match(tour,/scrollIntoView/);
assert.match(tour,/function typeText/);
assert.equal((tour.match(/targets:\[/g)||[]).length,6);
assert.match(css,/@media \(max-width: 480px\)/);
assert.match(css,/prefers-reduced-motion/);
assert.match(css,/\.kp-tour-shade \{/);
assert.match(css,/\.kp-tour-spotlight \{/);

new Function(tour);
console.log('OK: revision 29 onboarding/auth handoff, spotlight and six-step content contract.');
