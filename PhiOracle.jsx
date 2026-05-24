import { useState, useRef, useEffect } from "react";

const PHI = 1.6180339887;
const SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com";
const HOOK_V2 = "0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641";
const HOOK_V1 = "0x4c5888f9CDE99259D32b9887DEdd6239F53A8640";

const TIERS = [
  {tier:0,days:1},{tier:1,days:1},{tier:2,days:2},{tier:3,days:3},
  {tier:4,days:5},{tier:5,days:8},{tier:6,days:13},{tier:7,days:21},
  {tier:8,days:34},{tier:9,days:55},{tier:10,days:89},{tier:11,days:144},
];

const SYSTEM_PROMPT = `You are PHI-ORACLE — the official intelligence interface of the Phi-Hook protocol, a Uniswap V4 smart contract deployed on Ethereum Sepolia.

PROTOCOL FACTS:
- 12 Fibonacci tiers: 1,1,2,3,5,8,13,21,34,55,89,144 days
- Multipliers: tiers 0–9 = 1.000×, tier 10 (89d) = φ = 1.618×, tier 11 (144d) = φ² = 2.618×
- Protocol fee: 38.2% of LP fee (1/φ²) → 61.8% to LP reward pool, 38.2% to treasury
- Early exit penalty: max 5%, decays on φ-curve, 100% to reward pool
- ERC-6909 settlement — no ERC-20 approvals required
- Zero governance. Zero token inflation. 121/121 tests passing.
- GitHub: github.com/houariblr/phi-hook

RESPONSE FORMAT — you MUST always respond with valid JSON only, no markdown:
{
  "response": "Your official response here (under 180 words, precise, institutional tone)",
  "actions": [
    "Short clickable action 1 (max 8 words)",
    "Short clickable action 2 (max 8 words)",
    "Short clickable action 3 (max 8 words)"
  ]
}

Actions must be specific, actionable next steps relevant to what was just discussed. Examples:
- "Calculate yield for $10K over 144 days"
- "Explain the early exit penalty curve"
- "Compare Tier 3 vs Tier 11 returns"
- "How does ERC-6909 settlement work?"
- "What happens to my fees if I exit early?"
- "Show me the fee split math"

Always return valid JSON. Never include markdown or extra text outside the JSON.`;

async function checkContract(address) {
  try {
    const res = await fetch(SEPOLIA_RPC, {
      method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({jsonrpc:"2.0",id:1,method:"eth_getCode",params:[address,"latest"]})
    });
    const data = await res.json();
    return data.result && data.result !== "0x";
  } catch { return false; }
}

function useFonts() {
  useEffect(() => {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = "https://fonts.googleapis.com/css2?family=Source+Serif+4:wght@400;600&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap";
    document.head.appendChild(link);
    return () => { try { document.head.removeChild(link); } catch(e) {} };
  }, []);
}

function Seal() {
  return (
    <svg width="52" height="52" viewBox="0 0 52 52">
      <circle cx="26" cy="26" r="24" fill="none" stroke="#1B3A6B" strokeWidth="1.5"/>
      <circle cx="26" cy="26" r="19" fill="none" stroke="#1B3A6B" strokeWidth="0.75" strokeDasharray="3 2"/>
      <text x="26" y="22" textAnchor="middle" fontSize="14" fontWeight="700" fill="#1B3A6B" fontFamily="'IBM Plex Sans',sans-serif">Φ</text>
      <text x="26" y="31" textAnchor="middle" fontSize="5.5" fill="#1B3A6B" fontFamily="'IBM Plex Sans',sans-serif" letterSpacing="1">PROTOCOL</text>
      <text x="26" y="38" textAnchor="middle" fontSize="4.5" fill="#3B82C4" fontFamily="'IBM Plex Sans',sans-serif" letterSpacing="0.5">INTELLIGENCE</text>
    </svg>
  );
}

function Clock() {
  const [t, setT] = useState(new Date());
  useEffect(() => { const iv = setInterval(() => setT(new Date()), 1000); return () => clearInterval(iv); }, []);
  return <span style={{fontFamily:"'IBM Plex Mono',monospace",fontSize:11,color:"#6B7280"}}>{t.toISOString().replace("T"," ").slice(0,19)} UTC</span>;
}

function StatusDot({ ok }) {
  return <span style={{display:"inline-block",width:7,height:7,borderRadius:"50%",background:ok===null?"#D1D5DB":ok?"#16A34A":"#DC2626",verticalAlign:"middle",marginRight:5}} />;
}

function ActionButtons({ actions, onSelect, visible }) {
  if (!visible || !actions || actions.length === 0) return null;
  return (
    <div style={{marginTop:16,marginLeft:44,display:"flex",flexDirection:"column",gap:6,animation:"fadeUp 0.3s ease"}}>
      <div style={{fontSize:10,color:"#9CA3AF",fontFamily:"'IBM Plex Mono',monospace",letterSpacing:"0.08em",marginBottom:2}}>
        SUGGESTED NEXT ACTIONS:
      </div>
      <div style={{display:"flex",flexWrap:"wrap",gap:6}}>
        {actions.map((a,i) => (
          <button key={i} onClick={() => onSelect(a)} style={{
            background:"#EEF3FA",border:"1px solid #B8D0EC",
            color:"#1B3A6B",padding:"6px 14px",cursor:"pointer",
            fontFamily:"'IBM Plex Sans',sans-serif",fontSize:12,fontWeight:500,
            borderRadius:2,transition:"all 0.15s",textAlign:"left",
            display:"flex",alignItems:"center",gap:6
          }}
          onMouseEnter={e=>{e.currentTarget.style.background="#1B3A6B";e.currentTarget.style.color="#FFFFFF";e.currentTarget.style.borderColor="#1B3A6B";}}
          onMouseLeave={e=>{e.currentTarget.style.background="#EEF3FA";e.currentTarget.style.color="#1B3A6B";e.currentTarget.style.borderColor="#B8D0EC";}}>
            <span style={{color:"#9CA3AF",fontSize:10,fontFamily:"'IBM Plex Mono',monospace"}}>›</span>
            {a}
          </button>
        ))}
      </div>
    </div>
  );
}

function MsgBlock({ msg, isLast, onActionSelect }) {
  const isUser = msg.role === "user";
  const [displayed, setDisplayed] = useState("");
  const [done, setDone] = useState(false);

  const text = msg.parsed?.response || msg.content;

  useEffect(() => {
    if (isUser) { setDisplayed(msg.content); setDone(true); return; }
    if (!isLast) { setDisplayed(text); setDone(true); return; }
    setDisplayed(""); setDone(false);
    let i = 0;
    const iv = setInterval(() => {
      i++;
      setDisplayed(text.slice(0, i));
      if (i >= text.length) { clearInterval(iv); setDone(true); }
    }, 10);
    return () => clearInterval(iv);
  }, [text, isLast, isUser]);

  return (
    <div style={{marginBottom:24}}>
      <div style={{display:"flex",gap:12,alignItems:"flex-start"}}>
        <div style={{
          width:32,height:32,borderRadius:"50%",flexShrink:0,
          background:isUser?"#EEF3FA":"#1B3A6B",
          display:"flex",alignItems:"center",justifyContent:"center",
          fontSize:12,fontWeight:600,
          color:isUser?"#1B3A6B":"#FFFFFF",
          fontFamily:"'IBM Plex Sans',sans-serif",
          border:"1.5px solid",borderColor:isUser?"#B8D0EC":"#1B3A6B"
        }}>
          {isUser ? "OP" : "Φ"}
        </div>
        <div style={{flex:1,paddingTop:4}}>
          <div style={{fontSize:10,color:"#9CA3AF",fontFamily:"'IBM Plex Mono',monospace",marginBottom:5,letterSpacing:"0.05em"}}>
            {isUser ? "OPERATOR · CLEARANCE ALPHA" : "PHI-ORACLE · OFFICIAL RESPONSE"}
          </div>
          <div style={{fontSize:14,lineHeight:1.8,color:"#1F2937",fontFamily:"'IBM Plex Sans',sans-serif",whiteSpace:"pre-wrap"}}>
            {isUser ? msg.content : displayed}
            {!isUser && !done && <span style={{animation:"blink 0.8s step-end infinite",color:"#3B82C4"}}>▋</span>}
          </div>
        </div>
      </div>
      {!isUser && (
        <ActionButtons
          actions={msg.parsed?.actions}
          onSelect={onActionSelect}
          visible={isLast && done}
        />
      )}
    </div>
  );
}

export default function PhiOracle() {
  useFonts();
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [showTiers, setShowTiers] = useState(false);
  const [v2Status, setV2Status] = useState(null);
  const [v1Status, setV1Status] = useState(null);
  const bottomRef = useRef(null);

  useEffect(() => {
    checkContract(HOOK_V2).then(setV2Status);
    checkContract(HOOK_V1).then(setV1Status);
  }, []);

  useEffect(() => { bottomRef.current?.scrollIntoView({behavior:"smooth"}); }, [messages, loading]);

  const parseResponse = (raw) => {
    try {
      const cleaned = raw.replace(/```json|```/g,"").trim();
      return JSON.parse(cleaned);
    } catch {
      return { response: raw, actions: [] };
    }
  };

  const send = async (text) => {
    const msg = (text || input).trim();
    if (!msg || loading) return;
    setInput("");
    const userMsg = { role:"user", content:msg };
    const next = [...messages, userMsg];
    setMessages(next);
    setLoading(true);
    try {
      const res = await fetch("https://api.anthropic.com/v1/messages", {
        method:"POST", headers:{"Content-Type":"application/json"},
        body: JSON.stringify({
          model:"claude-sonnet-4-20250514", max_tokens:1000,
          system:SYSTEM_PROMPT,
          messages:next.map(m=>({role:m.role,content:m.content}))
        })
      });
      const data = await res.json();
      const raw = data.content?.[0]?.text || '{"response":"Error.","actions":[]}';
      const parsed = parseResponse(raw);
      setMessages(p => [...p, { role:"assistant", content:parsed.response, parsed }]);
    } catch {
      setMessages(p => [...p, { role:"assistant", content:"Connection interrupted.", parsed:{response:"Connection interrupted.",actions:[]} }]);
    }
    setLoading(false);
  };

  const ENTRY_POINTS = [
    { label:"Choose your commitment tier", desc:"Find the right Fibonacci gate for your capital", q:"I want to choose the right commitment tier for my liquidity. Walk me through the options." },
    { label:"Understand your yield", desc:"See exactly how φ-weighted rewards are calculated", q:"Explain how the golden ratio reward multiplier works and what yield I can expect." },
    { label:"Early exit scenarios", desc:"What happens if you need liquidity before the gate", q:"What happens if I need to withdraw before my Fibonacci gate? Explain the penalty curve." },
    { label:"Protocol fee mechanics", desc:"How 38.2% becomes real yield for committed LPs", q:"Explain the 38.2% protocol fee split and how it flows to LP rewards." },
  ];

  return (
    <div style={{height:"100vh",background:"#F0F4F9",display:"flex",flexDirection:"column",fontFamily:"'IBM Plex Sans',sans-serif",overflow:"hidden"}}>
      <style>{`
        @keyframes blink{0%,100%{opacity:1}50%{opacity:0}}
        @keyframes fadeUp{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:translateY(0)}}
        textarea:focus{outline:none}
        ::-webkit-scrollbar{width:4px}
        ::-webkit-scrollbar-track{background:#F0F4F9}
        ::-webkit-scrollbar-thumb{background:#B8D0EC;border-radius:2px}
      `}</style>

      <div style={{background:"#1B3A6B",color:"rgba(255,255,255,0.85)",fontSize:10.5,letterSpacing:"0.12em",textAlign:"center",padding:"5px 0",flexShrink:0,fontFamily:"'IBM Plex Mono',monospace"}}>
        OFFICIAL PROTOCOL INTELLIGENCE INTERFACE · PHI-HOOK · UNISWAP V4 · SEPOLIA TESTNET
      </div>

      <div style={{background:"#FFFFFF",borderBottom:"2px solid #1B3A6B",padding:"12px 24px",display:"flex",alignItems:"center",justifyContent:"space-between",flexShrink:0}}>
        <div style={{display:"flex",alignItems:"center",gap:16}}>
          <Seal />
          <div>
            <div style={{color:"#1B3A6B",fontSize:18,fontWeight:600,fontFamily:"'Source Serif 4',serif",letterSpacing:"0.02em"}}>PHI-ORACLE</div>
            <div style={{color:"#6B7280",fontSize:11,marginTop:1,fontFamily:"'IBM Plex Mono',monospace",letterSpacing:"0.08em"}}>FIBONACCI LIQUIDITY INTELLIGENCE SYSTEM</div>
          </div>
        </div>
        <div style={{display:"flex",alignItems:"center",gap:20}}>
          <Clock />
          <div style={{borderLeft:"1px solid #E5E7EB",paddingLeft:20,fontSize:11}}>
            <div style={{marginBottom:3}}><StatusDot ok={v2Status}/><span style={{color:"#374151",fontFamily:"'IBM Plex Mono',monospace"}}>Hook v2</span></div>
            <div><StatusDot ok={v1Status}/><span style={{color:"#374151",fontFamily:"'IBM Plex Mono',monospace"}}>Hook v1</span></div>
          </div>
          <button onClick={()=>setShowTiers(s=>!s)} style={{background:"transparent",border:"1.5px solid #1B3A6B",color:"#1B3A6B",padding:"6px 14px",cursor:"pointer",fontSize:11,letterSpacing:"0.08em",fontFamily:"'IBM Plex Mono',monospace",borderRadius:2}}>
            {showTiers?"HIDE TIERS":"VIEW TIERS"}
          </button>
        </div>
      </div>

      <div style={{background:"#EEF3FA",borderBottom:"1px solid #B8D0EC",padding:"6px 24px",display:"flex",gap:32,fontSize:11,color:"#374151",flexShrink:0}}>
        <span><span style={{color:"#6B7280"}}>PROTOCOL:</span> <strong>PHI-HOOK v2</strong></span>
        <span><span style={{color:"#6B7280"}}>TESTS:</span> <strong style={{color:"#16A34A"}}>121 / 121</strong></span>
        <span><span style={{color:"#6B7280"}}>AUDIT:</span> <strong style={{color:"#B45309"}}>Q3 2026 — PENDING</strong></span>
        <span><span style={{color:"#6B7280"}}>NETWORK:</span> <strong>Ethereum Sepolia</strong></span>
        <span style={{marginLeft:"auto"}}><a href="https://github.com/houariblr/phi-hook" target="_blank" rel="noreferrer" style={{color:"#1B3A6B",textDecoration:"none",fontWeight:500}}>github.com/houariblr/phi-hook ↗</a></span>
      </div>

      <div style={{display:"flex",flex:1,overflow:"hidden"}}>

        {showTiers && (
          <div style={{width:260,borderRight:"1px solid #D1D5DB",background:"#FFFFFF",padding:16,overflowY:"auto",flexShrink:0}}>
            <div style={{color:"#1B3A6B",fontSize:11,fontWeight:600,letterSpacing:"0.1em",marginBottom:12,paddingBottom:8,borderBottom:"2px solid #1B3A6B",fontFamily:"'IBM Plex Mono',monospace"}}>
              FIBONACCI TIER MATRIX
            </div>
            <table style={{width:"100%",borderCollapse:"collapse",fontSize:12}}>
              <thead>
                <tr style={{background:"#F0F4F9"}}>
                  <th style={{padding:"5px 8px",textAlign:"left",color:"#6B7280",fontWeight:500}}>Tier</th>
                  <th style={{padding:"5px 8px",textAlign:"left",color:"#6B7280",fontWeight:500}}>Gate</th>
                  <th style={{padding:"5px 8px",textAlign:"right",color:"#6B7280",fontWeight:500}}>Multiplier</th>
                </tr>
              </thead>
              <tbody>
                {TIERS.map(t => (
                  <tr key={t.tier} style={{borderBottom:"1px solid #F3F4F6"}}>
                    <td style={{padding:"5px 8px",color:"#6B7280",fontFamily:"'IBM Plex Mono',monospace"}}>T{t.tier}</td>
                    <td style={{padding:"5px 8px",color:"#1F2937",fontWeight:500}}>{t.days}d</td>
                    <td style={{padding:"5px 8px",textAlign:"right",color:t.days>=89?"#1B3A6B":"#374151",fontWeight:t.days>=89?600:400,fontFamily:"'IBM Plex Mono',monospace"}}>
                      {t.days===89?"1.618×":t.days===144?"2.618×":"1.000×"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div style={{marginTop:14,padding:12,background:"#EEF3FA",border:"1px solid #B8D0EC",borderRadius:2,fontSize:11,lineHeight:2,color:"#374151",fontFamily:"'IBM Plex Mono',monospace"}}>
              φ = 1.6180339887<br/>
              LP SHARE: 61.8% of fees<br/>
              TREASURY: 38.2% of fees<br/>
              MAX PENALTY: 5%<br/>
              GOVERNANCE: NONE
            </div>
            <div style={{marginTop:10,padding:10,background:"#F9FAFB",border:"1px solid #E5E7EB",borderRadius:2}}>
              <div style={{fontSize:10,color:"#6B7280",marginBottom:6,fontWeight:500,fontFamily:"'IBM Plex Mono',monospace"}}>ON-CHAIN STATUS</div>
              <div style={{fontSize:11,fontFamily:"'IBM Plex Mono',monospace",color:"#1B3A6B",lineHeight:2}}>
                <div><StatusDot ok={v2Status}/>v2: {HOOK_V2.slice(0,14)}...</div>
                <div><StatusDot ok={v1Status}/>v1: {HOOK_V1.slice(0,14)}...</div>
              </div>
              <a href={`https://sepolia.etherscan.io/address/${HOOK_V2}`} target="_blank" rel="noreferrer" style={{fontSize:11,color:"#3B82C4",display:"block",marginTop:6}}>View on Etherscan ↗</a>
            </div>
          </div>
        )}

        <div style={{flex:1,display:"flex",flexDirection:"column",overflow:"hidden",background:"#FFFFFF"}}>
          <div style={{flex:1,overflowY:"auto",padding:"24px 32px"}}>

            {messages.length === 0 && (
              <div>
                <div style={{border:"1px solid #B8D0EC",borderLeft:"4px solid #1B3A6B",background:"#EEF3FA",padding:"16px 20px",marginBottom:28,borderRadius:2}}>
                  <div style={{fontSize:11,color:"#6B7280",fontFamily:"'IBM Plex Mono',monospace",letterSpacing:"0.08em",marginBottom:6}}>OFFICIAL BRIEFING · AUTHORIZED ACCESS</div>
                  <div style={{color:"#1B3A6B",fontSize:17,fontWeight:600,fontFamily:"'Source Serif 4',serif",marginBottom:8}}>Welcome to Phi-Hook Protocol Intelligence</div>
                  <div style={{color:"#374151",fontSize:13,lineHeight:1.75}}>
                    This interface guides you through the Phi-Hook protocol — a Uniswap V4 hook that uses Fibonacci commitment gates and golden ratio reward curves to create mathematically grounded LP retention. Select a topic below to begin, or type your own query.
                  </div>
                </div>

                <div style={{fontSize:11,color:"#6B7280",fontFamily:"'IBM Plex Mono',monospace",letterSpacing:"0.08em",marginBottom:12}}>
                  SELECT A TOPIC TO BEGIN YOUR BRIEFING:
                </div>

                <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:10,marginBottom:24}}>
                  {ENTRY_POINTS.map((ep,i) => (
                    <button key={i} onClick={() => send(ep.q)} style={{
                      background:"#F9FAFB",border:"1px solid #E5E7EB",
                      padding:"14px 16px",cursor:"pointer",textAlign:"left",
                      borderRadius:2,transition:"all 0.15s",borderLeft:"3px solid #B8D0EC"
                    }}
                    onMouseEnter={e=>{e.currentTarget.style.background="#EEF3FA";e.currentTarget.style.borderLeftColor="#1B3A6B";}}
                    onMouseLeave={e=>{e.currentTarget.style.background="#F9FAFB";e.currentTarget.style.borderLeftColor="#B8D0EC";}}>
                      <div style={{fontSize:13,fontWeight:600,color:"#1B3A6B",marginBottom:4}}>{ep.label}</div>
                      <div style={{fontSize:11,color:"#6B7280",lineHeight:1.5}}>{ep.desc}</div>
                    </button>
                  ))}
                </div>

                <div style={{display:"grid",gridTemplateColumns:"repeat(4,1fr)",gap:10}}>
                  {[
                    {label:"Tests Passing",value:"121 / 121",color:"#16A34A"},
                    {label:"Fuzzer Calls",value:"250,000+",color:"#1B3A6B"},
                    {label:"Protocol Fee",value:"1/φ² = 38.2%",color:"#374151"},
                    {label:"Governance",value:"ZERO",color:"#B45309"},
                  ].map((s,i) => (
                    <div key={i} style={{padding:"10px 12px",border:"1px solid #E5E7EB",borderRadius:2,background:"#F9FAFB"}}>
                      <div style={{fontSize:10,color:"#9CA3AF",fontFamily:"'IBM Plex Mono',monospace",marginBottom:3}}>{s.label}</div>
                      <div style={{fontSize:13,fontWeight:600,color:s.color,fontFamily:"'IBM Plex Mono',monospace"}}>{s.value}</div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {messages.map((msg,i) => (
              <MsgBlock
                key={i} msg={msg}
                isLast={i===messages.length-1}
                onActionSelect={(a) => send(a)}
              />
            ))}

            {loading && (
              <div style={{display:"flex",gap:12,alignItems:"flex-start",marginBottom:20}}>
                <div style={{width:32,height:32,borderRadius:"50%",background:"#1B3A6B",display:"flex",alignItems:"center",justifyContent:"center",fontSize:12,fontWeight:600,color:"#FFFFFF",flexShrink:0}}>Φ</div>
                <div style={{paddingTop:4}}>
                  <div style={{fontSize:10,color:"#9CA3AF",fontFamily:"'IBM Plex Mono',monospace",marginBottom:5}}>PHI-ORACLE · PROCESSING</div>
                  <div style={{fontSize:13,color:"#6B7280",fontFamily:"'IBM Plex Mono',monospace",animation:"blink 1.2s step-end infinite"}}>Analyzing protocol parameters...</div>
                </div>
              </div>
            )}
            <div ref={bottomRef} />
          </div>

          <div style={{borderTop:"1px solid #E5E7EB",padding:"14px 32px",background:"#F9FAFB",flexShrink:0}}>
            <div style={{fontSize:10,color:"#9CA3AF",fontFamily:"'IBM Plex Mono',monospace",marginBottom:8,letterSpacing:"0.08em"}}>DIRECT QUERY · OR CLICK A SUGGESTED ACTION ABOVE</div>
            <div style={{display:"flex",gap:10,alignItems:"flex-end",border:"1.5px solid #B8D0EC",padding:"10px 14px",background:"#FFFFFF",borderRadius:2}}>
              <span style={{color:"#1B3A6B",fontSize:14,marginBottom:2,fontFamily:"'IBM Plex Mono',monospace"}}>›</span>
              <textarea
                value={input}
                onChange={e=>setInput(e.target.value)}
                onKeyDown={e=>{if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();send();}}}
                placeholder="Ask about tiers, yields, penalties, fee mechanics..."
                rows={1}
                style={{flex:1,background:"transparent",border:"none",color:"#1F2937",fontSize:14,resize:"none",fontFamily:"'IBM Plex Sans',sans-serif",lineHeight:1.6,maxHeight:100,overflow:"auto"}}
              />
              <button onClick={()=>send()} disabled={!input.trim()||loading} style={{
                background:(!input.trim()||loading)?"#F3F4F6":"#1B3A6B",
                border:"none",color:(!input.trim()||loading)?"#9CA3AF":"#FFFFFF",
                padding:"7px 20px",cursor:"pointer",
                fontFamily:"'IBM Plex Mono',monospace",fontSize:11,
                letterSpacing:"0.1em",borderRadius:2,transition:"background 0.15s"
              }}>
                TRANSMIT
              </button>
            </div>
          </div>
        </div>
      </div>

      <div style={{background:"#1B3A6B",color:"rgba(255,255,255,0.5)",fontSize:10,textAlign:"center",padding:"4px 0",flexShrink:0,fontFamily:"'IBM Plex Mono',monospace",letterSpacing:"0.1em"}}>
        PHI-HOOK PROTOCOL · UNISWAP V4 · SEPOLIA · github.com/houariblr/phi-hook · φ = 1.618033...
      </div>
    </div>
  );
}
