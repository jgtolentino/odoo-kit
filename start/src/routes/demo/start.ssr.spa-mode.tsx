import { useEffect, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { getPunkSongs } from '@/data/demo.punk-songs'

export const Route = createFileRoute('/demo/start/ssr/spa-mode')({
  ssr: false,
  component: RouteComponent,
})

type PunkSong = { id: number; name: string; artist: string }

function RouteComponent() {
  const [punkSongs, setPunkSongs] = useState<PunkSong[]>([])

  useEffect(() => {
    getPunkSongs().then(setPunkSongs)
  }, [])

  return (
    <div>
      <h1>SPA Mode - Punk Songs</h1>
      <ul>
        {punkSongs.map((song) => (
          <li key={song.id}>
            {song.name} - {song.artist}
          </li>
        ))}
      </ul>
    </div>
  )
}
