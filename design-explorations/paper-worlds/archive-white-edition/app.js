const words=[
 ['liminal','adjective','/ˈlɪmɪnəl/','At a threshold; between one state and another.','“The empty bookstore felt like a liminal space.”'],
 ['petrichor','noun','/ˈpɛtrɪkɔːr/','The pleasant, earthy smell that follows rain on dry ground.','“Petrichor drifted through the open window.”'],
 ['palimpsest','noun','/ˈpælɪmpsɛst/','A manuscript reused after earlier writing has been erased.','“Faint letters lingered beneath the ink of the palimpsest.”'],
 ['susurrus','noun','/sʊˈsʌrəs/','A soft whispering or rustling sound.','“A susurrus of turning pages filled the room.”'],
 ['reverie','noun','/ˈrɛvəri/','A state of being pleasantly lost in thought.','“The rain drew her into a quiet reverie.”'],
 ['numinous','adjective','/ˈnuːmɪnəs/','Evoking a sense of mystery, awe, or spiritual presence.','“The old library had a numinous stillness.”']
];
const $=id=>document.getElementById(id);let index=0,busy=false,revealed=false,start=null,dragged=false;
function render(){const w=words[index];['word','part','pronunciation','definition','example'].forEach((id,i)=>$(id).textContent=w[i]);$('count').textContent=`${String(index+1).padStart(2,'0')} / 06`;$('word-number').textContent=String(index+1).padStart(3,'0');$('answer').hidden=true;$('reveal').hidden=false;revealed=false;}
function reveal(){if(busy)return;revealed=true;$('answer').hidden=false;$('reveal').hidden=true;}
function review(remember){if(busy)return;if(!revealed){reveal();$('feedback').textContent='Read the meaning, then decide what stayed.';return;}busy=true;const card=$('card');card.style.transform='';card.classList.remove('handling');$('remember').disabled=$('forget').disabled=true;
if(remember){card.classList.add('turning');}else{const jagged='49% 0, 52% 8%, 48% 16%, 53% 23%, 49% 31%, 51% 39%, 47% 47%, 52% 55%, 48% 63%, 53% 71%, 49% 80%, 52% 90%, 49% 100%';for(let side of ['left','right']){const piece=card.cloneNode(true);piece.removeAttribute('id');piece.removeAttribute('tabindex');piece.querySelectorAll('[id]').forEach(e=>e.removeAttribute('id'));piece.querySelectorAll('button').forEach(e=>e.tabIndex=-1);piece.classList.add('tear-piece',`tear-${side}`);piece.style.clipPath=side==='left'?`polygon(0 0, ${jagged}, 0 100%)`:`polygon(${jagged}, 100% 100%, 100% 0)`;$('tear-layer').appendChild(piece);}card.style.visibility='hidden';}
$('feedback').textContent=remember?'A page turned. A word kept.':'Not lost. Just waiting for another encounter.';
setTimeout(()=>{index=(index+1)%words.length;render();card.classList.remove('turning');card.style.visibility='';$('tear-layer').replaceChildren();busy=false;$('remember').disabled=$('forget').disabled=false;},matchMedia('(prefers-reduced-motion: reduce)').matches?30:960);}
$('reveal').addEventListener('click',e=>{e.stopPropagation();reveal();});$('remember').onclick=()=>review(true);$('forget').onclick=()=>review(false);
$('card').addEventListener('click',()=>{if(!dragged)reveal();});
$('card').addEventListener('keydown',e=>{if(e.key==='ArrowRight'||e.key==='ArrowLeft'){e.preventDefault();review(e.key==='ArrowRight');}if(e.key==='Enter'||e.key===' '){e.preventDefault();reveal();}});
$('card').addEventListener('pointerdown',e=>{if(busy||e.target.closest('button'))return;start={x:e.clientX,y:e.clientY};dragged=false;$('card').classList.add('handling');$('card').setPointerCapture(e.pointerId);});
$('card').addEventListener('pointermove',e=>{if(!start||busy)return;let dx=e.clientX-start.x;if(Math.abs(dx)>12)dragged=true;if(dragged)$('card').style.transform=`translateX(${dx*.32}px) rotate(${dx*.018}deg) rotateY(${Math.max(-22,Math.min(22,dx*.1))}deg)`;});
function end(e){if(!start)return;let dx=e.clientX-start.x,dy=e.clientY-start.y;start=null;$('card').classList.remove('handling');$('card').style.transform='';if(Math.abs(dx)>70&&Math.abs(dx)>Math.abs(dy))review(dx>0);}
$('card').addEventListener('pointerup',end);$('card').addEventListener('pointercancel',()=>{start=null;$('card').classList.remove('handling');$('card').style.transform='';});
document.querySelectorAll('[data-choice]').forEach(button=>button.onclick=()=>{document.body.dataset.theme=button.dataset.choice;document.querySelectorAll('[data-choice]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));});render();
