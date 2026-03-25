import { useState, useEffect } from 'react'
import { BarChart, Bar, PieChart, Pie, Cell, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts'
import { supabase } from '../lib/supabase'

const COLORS = ['#16a34a', '#2563eb', '#d97706', '#dc2626', '#7c3aed', '#0891b2', '#be185d', '#65a30d', '#ea580c', '#6366f1']

export default function DashboardPage() {
  const [stats, setStats] = useState({ total: 0, users: 0, synced: 0, models: 0 })
  const [diseaseData, setDiseaseData] = useState([])
  const [dailyData, setDailyData] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadDashboard()
  }, [])

  const loadDashboard = async () => {
    setLoading(true)

    // Total predictions
    const { count: total } = await supabase
      .from('predictions')
      .select('*', { count: 'exact', head: true })

    // Unique users
    const { data: usersData } = await supabase
      .from('predictions')
      .select('user_id')

    const uniqueUsers = new Set(usersData?.map(r => r.user_id) || []).size

    // Models count
    const { count: models } = await supabase
      .from('model_registry')
      .select('*', { count: 'exact', head: true })

    setStats({ total: total || 0, users: uniqueUsers, synced: total || 0, models: models || 0 })

    // Disease distribution
    const { data: diseaseRows } = await supabase
      .from('predictions')
      .select('predicted_class_name, leaf_type')

    if (diseaseRows) {
      const counts = {}
      diseaseRows.forEach(r => {
        const name = cleanLabel(r.predicted_class_name)
        counts[name] = (counts[name] || 0) + 1
      })
      const sorted = Object.entries(counts)
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count)
        .slice(0, 10)
      setDiseaseData(sorted)
    }

    // Daily scans (last 30 days)
    const thirtyDaysAgo = new Date()
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30)

    const { data: dailyRows } = await supabase
      .from('predictions')
      .select('created_at')
      .gte('created_at', thirtyDaysAgo.toISOString())
      .order('created_at', { ascending: true })

    if (dailyRows) {
      const dayCounts = {}
      dailyRows.forEach(r => {
        const day = r.created_at.slice(0, 10)
        dayCounts[day] = (dayCounts[day] || 0) + 1
      })
      setDailyData(
        Object.entries(dayCounts).map(([date, count]) => ({ date: date.slice(5), count }))
      )
    }

    setLoading(false)
  }

  if (loading) return <p>Loading...</p>

  return (
    <>
      <h1 className="page-title">Dashboard</h1>

      <div className="stats-grid">
        <div className="stat-card">
          <div className="label">Total Predictions</div>
          <div className="value">{stats.total.toLocaleString()}</div>
        </div>
        <div className="stat-card">
          <div className="label">Active Users</div>
          <div className="value">{stats.users}</div>
        </div>
        <div className="stat-card">
          <div className="label">Synced Predictions</div>
          <div className="value">{stats.synced.toLocaleString()}</div>
        </div>
        <div className="stat-card">
          <div className="label">Registered Models</div>
          <div className="value">{stats.models}</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
        <div className="card">
          <h3>Daily Scans (Last 30 Days)</h3>
          <ResponsiveContainer width="100%" height={250}>
            <BarChart data={dailyData}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="date" tick={{ fontSize: 11 }} />
              <YAxis allowDecimals={false} />
              <Tooltip />
              <Bar dataKey="count" fill="#16a34a" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>

        <div className="card">
          <h3>Disease Distribution (Top 10)</h3>
          <ResponsiveContainer width="100%" height={250}>
            <PieChart>
              <Pie data={diseaseData} dataKey="count" nameKey="name" outerRadius={90} label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}>
                {diseaseData.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}
              </Pie>
              <Tooltip />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>
    </>
  )
}

function cleanLabel(name) {
  if (!name) return 'Unknown'
  return name
    .replace(/^[A-Za-z]+___/, '')
    .replace(/_/g, ' ')
}
