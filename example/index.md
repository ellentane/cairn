# The Last Box

<div class="room" id="room">
  <div class="room-grid">
    <!-- LEFT COLUMN: Narrative & Room Scene -->
    <div class="narrative-col">
      <header class="scene-header">
        <h1 class="main-title">The Last Box</h1>
        <p class="clock-line"><span id="clock" class="clock-time">5:14</span> &mdash; the train leaves at 5:42</p>
      </header>

      <div class="window-frame">
        <div class="window" id="win">
          <div class="sky-bg"></div>
          <div class="sky-sun"></div>
          <div class="sky-silhouette"></div>
          <div class="glass-pane"></div>
          <div class="mullion-v"></div>
          <div class="mullion-h"></div>
          <div class="light-ray"></div>
          <div class="curtain-rod"></div>
          <div class="curtain left"></div>
          <div class="curtain right"></div>
          <div class="window-sill"></div>
        </div>
      </div>

      <div class="prose-card">
        <p class="prose">5:14 PM. The movers have taken the bed and the furniture. The apartment is empty, save for a single cardboard box on the floor and a brass scale beside it.</p>
        <p class="prose">You have 28 minutes before the 5:42 PM train leaves to start your new life. The box can hold at most 3,000 grams of belongings. Every item you choose carries a memory from your years here, and every choice costs one minute on the clock.</p>
        <p class="prose">Decide what to take, write your name on the shipping label, and seal the box before the evening train departs.</p>
      </div>

      <div class="story-card">
        <p id="story" class="story"></p>
      </div>

      <div class="ending off" id="ending">
        <div class="ending-card">
          <div class="ending-title">Departure Summary</div>
          <p class="ending-lead"><span id="e-time"></span> <span id="e-l1"></span></p>
          <p id="e-stay"></p>
          <p><span id="e-l2"></span><span id="e-name"></span></p>
          <div class="ending-items">
            <p id="e-mug"></p>
            <p id="e-coat"></p>
            <p id="e-notebook"></p>
            <p id="e-cassette"></p>
            <p id="e-photo"></p>
            <p id="e-note"></p>
            <p id="e-note-left"></p>
          </div>
          <p id="e-final" class="ending-final"></p>
        </div>
      </div>
    </div>

    <!-- RIGHT COLUMN: Packing Desk & Box -->
    <div class="workbench-col">
      <div class="box-section">
        <div class="box-head">
          <span class="box-title">CARDBOARD CONTAINER</span>
          <span class="boxlabel">3000 g capacity</span>
        </div>
        <div class="box" id="box">
          <div class="box-lip"></div>
          <div class="box-interior">
            <div class="layer" id="fill-mug"><span class="layer-name">the blue mug &bull; 400 g</span></div>
            <div class="layer" id="fill-coat"><span class="layer-name">the wool coat &bull; 1800 g</span></div>
            <div class="layer" id="fill-notebook"><span class="layer-name">the notebook &bull; 700 g</span></div>
            <div class="layer" id="fill-cassette"><span class="layer-name">the cassette player &bull; 1200 g</span></div>
            <div class="layer" id="fill-photo"><span class="layer-name">the photograph &bull; 100 g</span></div>
            <div class="layer" id="fill-note"><span class="layer-name">the note &bull; 0 g</span></div>
          </div>
        </div>
      </div>

      <div class="desk">
        <div class="desk-head">WHAT GOES IN THE BOX</div>
        <p class="desk-sub">Choose items to pack into the box. Opening the desk drawer costs 1 minute.</p>
        
        <div class="drawerline">
          <button id="drawer-btn">open the desk drawer</button>
        </div>

        <div class="inventory-rows">
          <div class="row" id="row-mug">
            <span class="item">the blue mug</span>
            <span class="wt">400 g</span>
            <button id="mug-btn">put it in</button>
          </div>
          <div class="row" id="row-coat">
            <span class="item">the wool coat</span>
            <span class="wt">1800 g</span>
            <button id="coat-btn">put it in</button>
          </div>
          <div class="row" id="row-notebook">
            <span class="item">the notebook</span>
            <span class="wt">700 g</span>
            <button id="notebook-btn">put it in</button>
          </div>
          <div class="row" id="row-cassette">
            <span class="item">the cassette player</span>
            <span class="wt">1200 g</span>
            <button id="cassette-btn">put it in</button>
          </div>
          <div class="row" id="row-photo">
            <span class="item">the photograph</span>
            <span class="wt">100 g</span>
            <button id="photo-btn">put it in</button>
          </div>
          <div class="row off" id="note-row">
            <span class="item">the note</span>
            <span class="wt">0 g</span>
            <button id="note-btn">put it in</button>
          </div>
        </div>

        <div class="ledger">
          <div class="ledger-stats">
            <p class="lw">weight so far: <span id="total">0</span> g</p>
            <p class="lw">the box will hold <span id="left">3000</span> g more</p>
          </div>

          <div class="nameline-wrapper" id="nameline">
            <label for="name" class="name-label">name on the shipping label:</label>
            <input id="name" placeholder="enter name to seal...">
          </div>

          <button id="seal">seal the box</button>
          <p id="fb" class="fb"></p>
        </div>
      </div>
    </div>
  </div>
</div>

<span id="zero" hidden>0</span>
<span id="one" hidden>1</span>
<span id="scratch" hidden></span>
<span id="w-mug" hidden>400</span>
<span id="w-coat" hidden>1800</span>
<span id="w-notebook" hidden>700</span>
<span id="w-cassette" hidden>1200</span>
<span id="w-photo" hidden>100</span>
<span id="w-note" hidden>0</span>
<span id="mem-mug" hidden>the chip on the rim is from the morning you moved in.</span>
<span id="mem-coat" hidden>the collar is worn thin on the left side, where you carried your bag.</span>
<span id="mem-notebook" hidden>the first page is a list of things you meant to do. none of them are crossed out.</span>
<span id="mem-cassette" hidden>the battery door is held shut with tape. you never fixed it.</span>
<span id="mem-photo" hidden>everyone in it is laughing. you don't remember who took it.</span>
<span id="mem-note" hidden>it is in your handwriting. you wrote it last week: the window sticks in august. the radiator knocks. it was a good room.</span>

```cairn-css
:root {
  color-scheme: dark;
  --bg-deep: #0f0e0c;
  --bg-card: #171512;
  --border-card: #2e2820;
  --amber-warm: #e8b56a;
  --amber-dim: #a8947a;
  --amber-bright: #f5d9a8;
  --text-primary: #e6dcc8;
  --text-muted: #9e917d;
  --font-serif: 'Georgia', 'Times New Roman', serif;
  --font-mono: 'JetBrains Mono', ui-monospace, monospace;
}

body {
  max-width: 100% !important;
  margin: 0 !important;
  padding: 2.5em 1.5em !important;
  box-sizing: border-box !important;
  width: 100% !important;
  background: var(--bg-deep) !important;
  color: var(--text-primary);
  font-family: var(--font-serif);
  font-size: 16px;
  line-height: 1.75;
  min-height: 100vh;
}

main {
  max-width: 100% !important;
  width: 100% !important;
  margin: 0 auto !important;
}

body::before {
  content: "";
  position: fixed;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(ellipse at center, transparent 55%, rgba(0, 0, 0, 0.65) 100%);
  z-index: 5;
}

main > h1 {
  display: none;
}

.room {
  max-width: 980px;
  margin: 0 auto;
  padding: 2.2em;
  position: relative;
  background: var(--bg-card);
  border: 1px solid var(--border-card);
  border-radius: 8px;
  box-shadow: 0 15px 40px rgba(0, 0, 0, 0.7);
  box-sizing: border-box;
  transition: background 1.5s, box-shadow 1.5s;
}

.room.dusk {
  background: #1c1510;
  border-color: #3d2b1d;
}

.room.dark {
  background: #12141c;
  border-color: #23293a;
}

.room.gone {
  background: #090a0d;
  border-color: #171922;
}

/* 2-Column Grid Layout */
.room-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 2.5em;
  align-items: start;
}

@media (max-width: 860px) {
  .room-grid {
    grid-template-columns: 1fr;
    gap: 2em;
  }
}

.scene-header {
  margin-bottom: 1.6em;
  text-align: left;
}

.main-title {
  font-family: var(--font-serif);
  font-size: 2.2rem;
  font-weight: 400;
  letter-spacing: -0.01em;
  color: var(--text-primary);
  margin: 0 0 0.3em;
  text-align: left;
  line-height: 1.2;
}

.clock-line {
  font-family: var(--font-mono);
  font-size: 13px;
  color: var(--amber-warm);
  letter-spacing: 0.08em;
  margin: 0;
  text-align: left;
}

.clock-time {
  font-weight: 700;
  color: var(--amber-bright);
}

/* ATMOSPHERIC REFINED WINDOW ARTWORK */
.window-frame {
  margin-bottom: 1.6em;
  width: 100%;
}

.window {
  width: 100%;
  height: 180px;
  box-sizing: border-box;
  position: relative;
  border: 7px solid #231c14;
  border-radius: 4px;
  background: #0f0d0a;
  box-shadow: inset 0 0 15px rgba(0, 0, 0, 0.8), 0 0 25px rgba(232, 181, 106, 0.18);
  transition: box-shadow 1.5s;
  overflow: hidden;
}

.sky-bg {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, #60a5fa 0%, #fcd34d 50%, #fb923c 85%, #f97316 100%);
  transition: background 1.5s ease;
}

.sky-sun {
  position: absolute;
  top: 15px;
  right: 60px;
  width: 50px;
  height: 50px;
  border-radius: 50%;
  background: radial-gradient(circle, rgba(255, 252, 235, 0.95) 0%, rgba(252, 211, 77, 0.6) 50%, transparent 80%);
  filter: blur(1px);
  transition: opacity 1.5s, transform 1.5s;
}

.sky-silhouette {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 45px;
  background: 
    radial-gradient(ellipse at 20% 100%, #1e1711 35px, transparent 36px),
    radial-gradient(ellipse at 50% 100%, #19130e 45px, transparent 46px),
    radial-gradient(ellipse at 80% 100%, #1e1711 30px, transparent 31px);
  opacity: 0.85;
}

.glass-pane {
  position: absolute;
  inset: 0;
  background: linear-gradient(135deg, rgba(255, 255, 255, 0.22) 0%, rgba(255, 255, 255, 0.04) 35%, transparent 35%);
  pointer-events: none;
  z-index: 2;
}

.mullion-v {
  position: absolute;
  top: 0; bottom: 0; left: 50%; width: 4px;
  transform: translateX(-50%);
  background: linear-gradient(90deg, #18130d, #2d241a 50%, #14100b);
  box-shadow: 0 0 4px rgba(0, 0, 0, 0.5);
  z-index: 3;
}

.mullion-h {
  position: absolute;
  left: 0; right: 0; top: 50%; height: 4px;
  transform: translateY(-50%);
  background: linear-gradient(180deg, #18130d, #2d241a 50%, #14100b);
  box-shadow: 0 0 4px rgba(0, 0, 0, 0.5);
  z-index: 3;
}

.light-ray {
  position: absolute;
  top: -20%; left: -10%; width: 120%; height: 140%;
  background: linear-gradient(135deg, rgba(255, 245, 210, 0.28) 0%, transparent 60%);
  pointer-events: none;
  z-index: 4;
  transition: opacity 1.5s;
}

.curtain-rod {
  position: absolute;
  top: 3px; left: -10px; right: -10px; height: 4px;
  background: #3e3325;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.6);
  z-index: 5;
}

.curtain {
  position: absolute;
  top: 4px; bottom: 0; width: 34px;
  background: linear-gradient(90deg, #1a1511 0%, #32281e 25%, #1d1712 50%, #2d2319 75%, #18130d 100%);
  box-shadow: 2px 0 8px rgba(0, 0, 0, 0.7);
  z-index: 5;
}

.curtain.left { left: 0; }
.curtain.right { right: 0; }

.window-sill {
  position: absolute;
  bottom: 0; left: -8px; right: -8px; height: 10px;
  background: linear-gradient(180deg, #32281e, #1a140e);
  border-top: 1px solid #4a3c2c;
  z-index: 6;
}

/* Dynamic Lighting Transitions */
.room.dusk .sky-bg {
  background: linear-gradient(180deg, #4c1d95 0%, #c026d3 30%, #ea580c 70%, #7c2d12 100%);
}

.room.dusk .sky-sun {
  opacity: 0.6;
  transform: translateY(25px);
  background: radial-gradient(circle, rgba(253, 186, 116, 0.95) 0%, rgba(234, 88, 12, 0.5) 60%, transparent 80%);
}

.room.dusk .window {
  box-shadow: inset 0 0 15px rgba(0, 0, 0, 0.8), 0 0 20px rgba(234, 88, 12, 0.18);
}

.room.dusk .light-ray {
  background: linear-gradient(135deg, rgba(251, 146, 60, 0.22) 0%, transparent 60%);
}

.room.dark .sky-bg {
  background: linear-gradient(180deg, #090d16 0%, #1e1b4b 50%, #311b92 85%, #1e1435 100%);
}

.room.dark .sky-sun {
  top: 20px;
  right: 70px;
  width: 32px;
  height: 32px;
  background: radial-gradient(circle, rgba(255, 255, 255, 0.95) 0%, rgba(224, 231, 255, 0.7) 60%, transparent 80%);
  box-shadow: 0 0 15px rgba(224, 231, 255, 0.8);
}

.room.dark .window {
  box-shadow: inset 0 0 15px rgba(0, 0, 0, 0.9), 0 0 15px rgba(99, 102, 241, 0.15);
}

.room.dark .light-ray {
  opacity: 0.15;
  background: linear-gradient(135deg, rgba(199, 210, 254, 0.15) 0%, transparent 60%);
}

.room.gone .sky-bg {
  background: linear-gradient(180deg, #020617 0%, #090d16 100%);
}

.room.gone .sky-sun {
  opacity: 0;
}

.room.gone .light-ray {
  opacity: 0;
}

.room.gone .window {
  box-shadow: inset 0 0 20px rgba(0, 0, 0, 0.95);
}

/* Prose Narrative */
.prose-card {
  margin-bottom: 1.5em;
  text-align: left;
}

.prose {
  color: var(--text-primary);
  font-size: 1.02rem;
  margin: 0.9em 0;
  letter-spacing: 0.01em;
  text-align: left;
}

/* Memory Story Block - HIDDEN WHEN EMPTY */
.story-card {
  margin: 1.4em 0;
  display: none;
}

.story-card:has(.story:not(:empty)) {
  display: block;
  border-left: 2px solid var(--amber-warm);
  padding: 0.4em 0 0.4em 1em;
  background: rgba(232, 181, 106, 0.05);
  border-radius: 0 4px 4px 0;
  text-align: left;
}

.story {
  font-style: italic;
  color: var(--amber-warm);
  margin: 0;
  font-size: 1.02rem;
}

/* Cardboard Box Section */
.box-section {
  text-align: left;
  margin-bottom: 1.5em;
  width: 100%;
}

.box-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 0.6em;
  line-height: 1.2;
}

.box-title {
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: 0.24em;
  color: var(--amber-dim);
  text-transform: uppercase;
}

.boxlabel {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--amber-dim);
  margin: 0;
  text-align: right;
}

.box {
  width: 100%;
  height: 170px;
  position: relative;
  border: 2px solid #4a4234;
  border-bottom: 5px solid #3a332a;
  border-radius: 4px;
  background: #14110d;
  padding: 6px;
  box-sizing: border-box;
  display: flex;
  flex-direction: column-reverse;
  gap: 4px;
}

.box-lip {
  position: absolute;
  top: -6px; left: -2px; right: -2px; height: 10px;
  background: #1d1913;
  border: 2px solid #4a4234;
  border-radius: 3px 3px 0 0;
  z-index: 2;
}

.box.sealed .box-lip::after {
  content: "";
  position: absolute;
  top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  width: 90px; height: 8px;
  background: rgba(232, 181, 106, 0.45);
  border-radius: 2px;
}

.box-interior {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column-reverse;
  gap: 4px;
  position: relative;
  z-index: 2;
}

.layer {
  position: relative;
  height: 22px;
  width: 100%;
  border-radius: 3px;
  background: linear-gradient(180deg, rgba(232, 181, 106, 0.55), rgba(232, 181, 106, 0.35));
  opacity: 0;
  transition: opacity 400ms ease;
  display: flex;
  align-items: center;
  padding: 0 10px;
  box-sizing: border-box;
}

.layer-name {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.08em;
  color: #14120e;
  font-weight: 600;
}

#fill-mug { background: linear-gradient(90deg, rgba(56, 189, 248, 0.7), rgba(2, 132, 199, 0.5)); }
#fill-coat { background: linear-gradient(90deg, rgba(129, 140, 248, 0.7), rgba(79, 70, 229, 0.5)); }
#fill-notebook { background: linear-gradient(90deg, rgba(52, 211, 153, 0.7), rgba(5, 150, 105, 0.5)); }
#fill-cassette { background: linear-gradient(90deg, rgba(192, 132, 252, 0.7), rgba(147, 51, 234, 0.5)); }
#fill-photo { background: linear-gradient(90deg, rgba(251, 113, 133, 0.7), rgba(225, 29, 72, 0.5)); }
#fill-note { background: linear-gradient(90deg, rgba(251, 191, 36, 0.8), rgba(217, 119, 6, 0.6)); }

.layer.on {
  opacity: 1;
}

/* Desk Inventory */
.desk {
  background: #1a1712;
  border: 1px solid #3a332a;
  border-radius: 6px;
  padding: 1.3em;
  text-align: left;
}

.desk-head {
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: 0.24em;
  color: var(--amber-dim);
  border-bottom: 1px solid #2a251d;
  padding-bottom: 0.6em;
  margin-bottom: 0.5em;
  text-align: left;
}

.desk-sub {
  font-family: var(--font-serif);
  font-size: 0.9rem;
  color: var(--text-muted);
  margin: 0.4em 0 0.8em;
  line-height: 1.4;
  text-align: left;
}

.drawerline {
  margin: 0.7em 0 1em;
  text-align: left;
}

.inventory-rows {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.row {
  display: grid;
  grid-template-columns: 1fr 75px 95px;
  align-items: center;
  gap: 12px;
  padding: 0.6em 0.5em;
  border-bottom: 1px dotted #2a251d;
  transition: background 150ms ease;
  background: transparent;
}

.row.off { display: none; }

.row:hover {
  background: rgba(232, 181, 106, 0.15);
  border-radius: 4px;
}

.item {
  font-family: var(--font-serif);
  font-size: 0.98rem;
  color: var(--text-primary);
  text-align: left;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.wt {
  font-family: var(--font-mono);
  font-size: 13px;
  color: var(--amber-dim);
  text-align: right;
}

button {
  font-family: var(--font-serif);
  font-size: 13px;
  background: transparent;
  border: 1px solid #4a4234;
  border-radius: 3px;
  padding: 4px 10px;
  cursor: pointer;
  color: var(--text-primary);
  text-align: center;
  width: 100%;
  box-sizing: border-box;
  transition: all 150ms ease;
  white-space: nowrap;
}

button:hover {
  border-color: var(--amber-warm);
  color: var(--amber-warm);
}

button:focus-visible, input:focus-visible {
  outline: 2px solid var(--amber-warm);
  outline-offset: 1px;
}

.room.sealed .row button,
.room.sealed #drawer-btn,
.room.sealed input,
.room:has(#box.sealed) .row button,
.room:has(#box.sealed) #drawer-btn,
.room:has(#box.sealed) input {
  pointer-events: none !important;
  opacity: 0.35 !important;
  cursor: not-allowed !important;
}

.ledger {
  margin-top: 1.2em;
  text-align: left;
}

.ledger-stats {
  margin-bottom: 0.8em;
}

.lw {
  font-family: var(--font-mono);
  font-size: 13px;
  color: var(--amber-dim);
  margin: 0.35em 0;
  text-align: left;
}

.nameline-wrapper {
  margin: 0.8em 0;
  padding: 0.3em 0.4em;
  border-radius: 3px;
  transition: background 150ms;
  text-align: left;
}

.nameline-wrapper.glow {
  background: rgba(232, 181, 106, 0.12);
}

.name-label {
  font-family: var(--font-mono);
  font-size: 13px;
  color: var(--amber-dim);
  display: block;
  margin-bottom: 0.3em;
}

input {
  font-family: var(--font-mono);
  font-size: 13px;
  background: #14110d;
  border: 1px solid #4a4234;
  border-radius: 3px;
  padding: 6px 10px;
  color: var(--text-primary);
  width: 100%;
  box-sizing: border-box;
}

#seal {
  margin-top: 0.9em;
  width: 100%;
  font-family: var(--font-mono);
  font-size: 12px;
  letter-spacing: 0.18em;
  text-transform: uppercase;
  background: var(--amber-warm);
  color: #14120e;
  border: none;
  border-radius: 3px;
  padding: 10px 18px;
  font-weight: 700;
}

#seal:hover {
  background: #f3c77e;
  color: #14120e;
}

.fb {
  font-family: var(--font-serif);
  font-size: 14px;
  color: var(--amber-warm);
  min-height: 1.4em;
  margin: 0.6em 0 0;
  text-align: center;
}

/* Epilogue Ending Panel */
.ending {
  margin-top: 1.8em;
  text-align: left;
}

.ending.off { display: none; }

.ending-card {
  border-top: 1px solid var(--amber-warm);
  padding-top: 1em;
  text-align: left;
}

.ending-title {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.2em;
  text-transform: uppercase;
  color: var(--amber-warm);
  margin-bottom: 0.6em;
}

.ending-lead {
  font-size: 1.05rem;
  color: var(--text-primary);
}

.ending-items p {
  margin: 0.4em 0;
  color: var(--text-muted);
  font-size: 0.98rem;
}

.ending-final {
  margin-top: 1em !important;
  color: var(--text-primary) !important;
  font-weight: 600;
}

.ending p { margin: 0.5em 0; }
.ending p:empty { display: none; }

#e-time { color: var(--amber-warm); font-family: var(--font-mono); font-weight: 700; }
#e-stay { color: var(--amber-warm); font-style: italic; }
#e-l2 { font-style: italic; }
#e-name { font-style: italic; font-weight: 700; color: var(--amber-warm); }
#e-final { margin-top: 0.9em; }
```

```cairn
let total = 0;
let cand = 0;
let w = 0;
let m = 0;
let name = 0;
let min = 14;
let m60 = 0;
let m120 = 0;
let mug = 0;
let coat = 0;
let notebook = 0;
let cassette = 0;
let photo = 0;
let note = 0;
let drawer = 0;

on hover "#row-mug" { add_class "lit" on "#row-mug"; }
on hover "#row-coat" { add_class "lit" on "#row-coat"; }
on hover "#row-notebook" { add_class "lit" on "#row-notebook"; }
on hover "#row-cassette" { add_class "lit" on "#row-cassette"; }
on hover "#row-photo" { add_class "lit" on "#row-photo"; }
on hover "#row-note" { add_class "lit" on "#row-note"; }
on hover "#note-row" { add_class "lit" on "#note-row"; }
on focus "#name" { add_class "glow" on "#nameline"; }
on blur "#name" { remove_class "glow" on "#nameline"; }

on click "#drawer-btn" {
    if drawer == "0" {
        extract_text "#one" to drawer;
        remove_class "off" on "#note-row";
        set_text "the drawer is open. the note is inside." on "#story";
        inc min;
        if min >= "120" {
            set_text min - 120 on "#scratch";
            extract_text "#scratch" to m120;
            if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
        } else {
            if min >= "60" {
                set_text min - 60 on "#scratch";
                extract_text "#scratch" to m60;
                if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
            } else {
                if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
            }
        }
        if min >= "42" { add_class "gone" on "#room"; }
        else { if min >= "35" { add_class "dark" on "#room"; }
        else { if min >= "25" { add_class "dusk" on "#room"; } } }
    } else {
        set_text "the drawer is already open." on "#story";
    }
}

on click "#mug-btn" {
    if mug == "0" {
        extract_text "#w-mug" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to mug;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-mug" to m;
            set_text m on "#story";
            set_text "take it out" on "#mug-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-mug";
        }
    } else {
        extract_text "#w-mug" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to mug;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the mug back on the sill." on "#story";
        set_text "put it in" on "#mug-btn";
        remove_class "on" on "#fill-mug";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}
on click "#coat-btn" {
    if coat == "0" {
        extract_text "#w-coat" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to coat;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-coat" to m;
            set_text m on "#story";
            set_text "take it out" on "#coat-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-coat";
        }
    } else {
        extract_text "#w-coat" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to coat;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the coat back on the chair." on "#story";
        set_text "put it in" on "#coat-btn";
        remove_class "on" on "#fill-coat";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}
on click "#notebook-btn" {
    if notebook == "0" {
        extract_text "#w-notebook" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to notebook;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-notebook" to m;
            set_text m on "#story";
            set_text "take it out" on "#notebook-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-notebook";
        }
    } else {
        extract_text "#w-notebook" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to notebook;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the notebook back on the desk." on "#story";
        set_text "put it in" on "#notebook-btn";
        remove_class "on" on "#fill-notebook";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}
on click "#cassette-btn" {
    if cassette == "0" {
        extract_text "#w-cassette" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to cassette;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-cassette" to m;
            set_text m on "#story";
            set_text "take it out" on "#cassette-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-cassette";
        }
    } else {
        extract_text "#w-cassette" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to cassette;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the cassette player back on the floor." on "#story";
        set_text "put it in" on "#cassette-btn";
        remove_class "on" on "#fill-cassette";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}
on click "#photo-btn" {
    if photo == "0" {
        extract_text "#w-photo" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to photo;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-photo" to m;
            set_text m on "#story";
            set_text "take it out" on "#photo-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-photo";
        }
    } else {
        extract_text "#w-photo" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to photo;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the photograph back on the sill." on "#story";
        set_text "put it in" on "#photo-btn";
        remove_class "on" on "#fill-photo";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}
on click "#note-btn" {
    if note == "0" {
        extract_text "#w-note" to w;
        set_text total + w on "#scratch";
        extract_text "#scratch" to cand;
        if cand > "3000" {
            set_text "the box won't close. something has to come out." on "#fb";
        } else {
            extract_text "#one" to note;
            extract_text "#scratch" to total;
            set_text cand on "#total";
            set_text 3000 - cand on "#left";
            extract_text "#mem-note" to m;
            set_text m on "#story";
            set_text "take it out" on "#note-btn";
            set_text "" on "#fb";
            add_class "on" on "#fill-note";
        }
    } else {
        extract_text "#w-note" to w;
        set_text total - w on "#scratch";
        extract_text "#scratch" to total;
        extract_text "#zero" to note;
        set_text total on "#total";
        set_text 3000 - total on "#left";
        set_text "you put the note back in the drawer." on "#story";
        set_text "put it in" on "#note-btn";
        remove_class "on" on "#fill-note";
    }
    inc min;
    if min >= "120" {
        set_text min - 120 on "#scratch";
        extract_text "#scratch" to m120;
        if m120 < "10" { set_text "7:0" + m120 on "#clock"; } else { set_text "7:" + m120 on "#clock"; }
    } else {
        if min >= "60" {
            set_text min - 60 on "#scratch";
            extract_text "#scratch" to m60;
            if m60 < "10" { set_text "6:0" + m60 on "#clock"; } else { set_text "6:" + m60 on "#clock"; }
        } else {
            if min < "10" { set_text "5:0" + min on "#clock"; } else { set_text "5:" + min on "#clock"; }
        }
    }
    if min >= "42" { add_class "gone" on "#room"; }
    else { if min >= "35" { add_class "dark" on "#room"; }
    else { if min >= "25" { add_class "dusk" on "#room"; } } }
}

on click "#seal" {
    extract_value "#name" to name;
    if name == "" {
        set_text "write your name on the label first." on "#fb";
    } else {
        remove_class "off" on "#ending";
        set_text "" on "#fb";
        set_text "" on "#e-l1";
        set_text "" on "#e-stay";
        set_text "" on "#e-name";
        set_text "" on "#e-mug";
        set_text "" on "#e-coat";
        set_text "" on "#e-notebook";
        set_text "" on "#e-cassette";
        set_text "" on "#e-photo";
        set_text "" on "#e-note";
        set_text "" on "#e-note-left";
        set_text "" on "#e-final";
        if min >= "120" {
            set_text min - 120 on "#scratch";
            extract_text "#scratch" to m120;
            if m120 < "10" { set_text "7:0" + m120 + "." on "#e-time"; } else { set_text "7:" + m120 + "." on "#e-time"; }
        } else {
            if min >= "60" {
                set_text min - 60 on "#scratch";
                extract_text "#scratch" to m60;
                if m60 < "10" { set_text "6:0" + m60 + "." on "#e-time"; } else { set_text "6:" + m60 + "." on "#e-time"; }
            } else {
                if min < "10" { set_text "5:0" + min + "." on "#e-time"; } else { set_text "5:" + min + "." on "#e-time"; }
            }
        }
        if min >= "42" {
            set_text "the train is gone. you stay the night." on "#e-l1";
            set_text "you unpack. the box can wait until tomorrow. the room is not empty tonight." on "#e-stay";
            set_text "you leave the box where it is." on "#e-l2";
            set_text "the train is gone" on "#seal";
        } else {
            add_class "sealed" on "#box";
            add_class "sealed" on "#room";
            if min >= "35" {
                set_text "you ran the last stretch." on "#e-l1";
            } else {
                if min >= "25" {
                    set_text "you made it. the light outside is going." on "#e-l1";
                } else {
                    set_text "you made it with time to spare." on "#e-l1";
                }
            }
            if total == "0" {
                if note == "0" {
                    set_text "you seal the empty box. there was nothing to take." on "#e-l2";
                    set_text "the room is empty, and so is the box." on "#e-final";
                } else {
                    set_text "the box is sealed. on the label, in your handwriting: " on "#e-l2";
                    set_text name on "#e-name";
                    set_text "your note to the next tenant is in the box. you kept it." on "#e-note";
                    set_text "the room is empty. it was a good room." on "#e-final";
                }
            } else {
                set_text "the box is sealed. on the label, in your handwriting: " on "#e-l2";
                set_text name on "#e-name";
                if mug == "1" { set_text "the mug is packed. you will drink from it somewhere else." on "#e-mug"; }
                if coat == "1" { set_text "the coat is packed. it will smell of another winter, eventually." on "#e-coat"; }
                if notebook == "1" { set_text "the list of things you meant to do is in the box. maybe you will do some of them." on "#e-notebook"; }
                if cassette == "1" { set_text "the cassette player is in the box. you will fix it this winter." on "#e-cassette"; }
                if photo == "1" { set_text "the photograph is on top. you look at it once more before the lid goes on." on "#e-photo"; }
                if note == "1" { set_text "your note to the next tenant is in the box. you kept it." on "#e-note"; }
                else { if drawer == "1" { set_text "the note stays in the drawer. someone else will find it." on "#e-note-left"; } else { set_text "the note stays in the drawer, unread." on "#e-note-left"; } }
                if note == "1" { set_text "the room is empty. it was a good room." on "#e-final"; }
                else { set_text "the room is empty. it was a good room. someone else will say that, too." on "#e-final"; }
            }
            set_text "sealed" on "#seal";
        }
    }
}
```
