import { memo } from 'react'

export default memo(function CustomTooltip({ active, payload, label }) {
  if (!active || !payload?.length) return null
  return (
    <div style={{ background: '#fff', borderRadius: 8, padding: '8px 12px', boxShadow: '0 8px 24px rgba(18,28,40,0.12)', border: '1px solid rgba(0,0,0,0.08)', fontSize: 12 }}>
      <div style={{ fontWeight: 600, marginBottom: 3, color: '#121c28' }}>{label}</div>
      {payload.map((p, i) => (
        <div key={i} style={{ color: p.color }}>{p.name}: <b>{p.value}{p.unit || ''}</b></div>
      ))}
    </div>
  )
})
