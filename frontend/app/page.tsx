import { GalleryVerticalEnd } from "lucide-react"

import { LoginForm } from "@/components/login-form"
import {cn} from "@/lib/utils";
import {Card, CardContent, CardDescription, CardHeader, CardTitle} from "@/components/ui/card";
import {Field, FieldDescription, FieldGroup, FieldLabel, FieldSeparator} from "@/components/ui/field";
import {Button} from "@/components/ui/button";
import {Input} from "@/components/ui/input";
import {MessageScrollerProvider} from "@/components/ui/message-scroller";
import {MessageScroller} from "@shadcn/react/message-scroller";

export default function LoginPage() {
  return (
      <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted p-6 md:p-10">
        <div className="flex w-full max-w-lg flex-col gap-6">
          <a href="#" className="flex items-center gap-2 self-center font-medium">
            Shoes
          </a>
            <div className="flex flex-col gap-6">
                <Card>

                    <CardContent>
                            <MessageScroller>{/* streamed turns */}</MessageScroller>
                    </CardContent>
                </Card>
                <FieldDescription className="px-6 text-center">
                    Made by @jerrens (Discord)
                </FieldDescription>
            </div>
        </div>
      </div>
  )
}
