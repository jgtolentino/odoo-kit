'use client'

import { useState } from 'react'
import { useMobile } from '@/hooks/use-mobile'
import { Button } from '@/components/ui/button'
import SupabaseManagerDialog from '@/components/supabase-manager'
import { 
  Card, 
  CardContent, 
  CardDescription, 
  CardHeader, 
  CardTitle 
} from '@/components/ui/card'
import { 
  Database, 
  HardDrive, 
  Shield, 
  Users, 
  KeyRound, 
  ScrollText, 
  Lightbulb,
  Zap
} from 'lucide-react'

export default function HomePage() {
  const [open, setOpen] = useState(false)
  const isMobile = useMobile()
  const projectRef = 'demo-project' // Replace with your actual project ref

  const features = [
    {
      title: 'Database',
      description: 'Manage tables, columns, and data with an intuitive interface',
      icon: Database,
    },
    {
      title: 'Storage',
      description: 'Upload, organize, and manage files and media assets',
      icon: HardDrive,
    },
    {
      title: 'Authentication',
      description: 'Configure auth providers and manage user sign-up flows',
      icon: Shield,
    },
    {
      title: 'Users',
      description: 'View, manage, and monitor all registered users',
      icon: Users,
    },
    {
      title: 'Secrets',
      description: 'Securely store and manage environment secrets',
      icon: KeyRound,
    },
    {
      title: 'Logs',
      description: 'Monitor and analyze application logs in real-time',
      icon: ScrollText,
    },
    {
      title: 'AI Suggestions',
      description: 'Get AI-powered suggestions for SQL queries and optimization',
      icon: Lightbulb,
    },
  ]

  return (
    <div className="min-h-screen bg-gradient-to-br from-background via-background to-muted/20">
      {/* Header */}
      <header className="sticky top-0 z-40 border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
        <div className="container flex h-16 items-center justify-between">
          <div className="flex items-center gap-2">
            <Zap className="h-6 w-6 text-primary" />
            <h1 className="text-xl font-bold">Supabase Platform Manager</h1>
          </div>
          <Button onClick={() => setOpen(true)} size="lg" className="gap-2">
            <span>Open Manager</span>
            <Zap className="h-4 w-4" />
          </Button>
        </div>
      </header>

      {/* Main Content */}
      <main className="container py-12">
        <div className="mb-12 text-center">
          <h2 className="text-3xl font-bold tracking-tight sm:text-4xl mb-4">
            Manage Your Backend with Ease
          </h2>
          <p className="text-lg text-muted-foreground max-w-2xl mx-auto mb-8">
            Access all your Supabase features in one unified interface. Manage database, authentication, storage, and more without leaving your app.
          </p>
          <Button onClick={() => setOpen(true)} size="lg" variant="default">
            Get Started
          </Button>
        </div>

        {/* Features Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 mb-12">
          {features.map((feature) => {
            const Icon = feature.icon
            return (
              <Card 
                key={feature.title} 
                className="border-muted hover:border-primary/50 transition-colors"
              >
                <CardHeader>
                  <div className="flex items-start justify-between">
                    <div className="flex-1">
                      <CardTitle className="flex items-center gap-2">
                        <Icon className="h-5 w-5 text-primary" />
                        {feature.title}
                      </CardTitle>
                    </div>
                  </div>
                </CardHeader>
                <CardContent>
                  <CardDescription>{feature.description}</CardDescription>
                </CardContent>
              </Card>
            )
          })}
        </div>

        {/* CTA Section */}
        <Card className="border-primary/20 bg-primary/5">
          <CardHeader className="text-center">
            <CardTitle className="text-2xl">Ready to Manage Your Backend?</CardTitle>
            <CardDescription className="text-base mt-2">
              All features are fully activated and ready to use. Click the button below to open the complete manager interface.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex justify-center">
            <Button onClick={() => setOpen(true)} size="lg" className="gap-2">
              Open Full Manager Interface
              <Zap className="h-4 w-4" />
            </Button>
          </CardContent>
        </Card>
      </main>

      {/* Manager Dialog - All Features Activated */}
      <SupabaseManagerDialog
        projectRef={projectRef}
        open={open}
        onOpenChange={setOpen}
        isMobile={isMobile}
      />
    </div>
  )
}
