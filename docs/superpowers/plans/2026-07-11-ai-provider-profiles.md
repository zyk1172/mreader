# AI Provider Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Save multiple OpenAI-compatible parent profiles and child models while every translation uses one selected child model only.

**Architecture:** Persist profile metadata in UserDefaults and API keys in Keychain. Resolve one active configuration at request time, remove model-pool failover from AITranslator, and migrate legacy settings into a default profile.

**Tech Stack:** Swift 6, SwiftUI, Security, URLSession, XCTest, Xcode 27 Beta.

## Tasks

1. Add failing tests for profile normalization, migration, active selection, and single-model policy.
2. Implement AIProviderProfile and AIProviderStore with Keychain-backed credentials.
3. Replace model-pool UI with parent profile and child-model management.
4. Resolve the active profile in Reader and remove automatic model attempts from AITranslator.
5. Extend settings backup to version 6 and migrate legacy backups.
6. Remove obsolete model-pool manager, status UI, and tests.
7. Run all tests, build with Xcode Beta, then install and launch on 郑云凯.
