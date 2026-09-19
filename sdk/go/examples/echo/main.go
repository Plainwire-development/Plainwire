package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"plainwire.local/bot-sdk-go/plainwirebot"
)

func main() {
	base := os.Getenv("PLAINWIRE_BASE_URL")
	if base == "" {
		base = "http://127.0.0.1:8080"
	}
	bot, err := plainwirebot.New(base, os.Getenv("PLAINWIRE_BOT_TOKEN"))
	if err != nil {
		log.Fatal(err)
	}
	ctx := context.Background()
	if _, err := bot.RegisterCommand(ctx, "echo", "Echo text back to the channel", nil); err != nil {
		log.Fatal(err)
	}
	for {
		claims, err := bot.ClaimCommands(ctx, 20)
		if err != nil {
			log.Printf("claim: %v", err)
			time.Sleep(time.Second)
			continue
		}
		for _, claim := range claims {
			raw, _ := claim.Args["raw"].(string)
			if _, err := bot.RespondCommand(ctx, claim, raw); err != nil {
				log.Printf("respond %d: %v", claim.ID, err)
			} else {
				fmt.Printf("handled /%s invocation %d\n", claim.Command, claim.ID)
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
}
