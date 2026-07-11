# MReader AI Provider Profiles Design

## Goal

Replace model-pool round-robin and automatic failover with saved parent API
profiles and child model names. OCR and vision translation always share one
explicitly selected child model.

## Data model

AIProviderProfile stores non-secret metadata:

- stable UUID
- display name
- OpenAI-compatible Base URL
- child model names
- selected child model
- creation and update timestamps

API keys are stored in Keychain by profile UUID. UserDefaults stores profile
metadata and the active profile ID. The legacy Base URL, API key, default model,
and model-pool text migrate once into a profile named 默认接口; the default
model is selected and unique pool entries become additional child models.

## Request behavior

Every OCR, page translation, visual recognition, and visual translation request
resolves the active profile immediately before starting. It sends exactly the
active profile's selected child model. There is no round-robin index, rate-limit
record, midnight reset, circuit breaker, next-model attempt, or default-model
fallback. A failed request reports the selected profile and model and stops.

The existing structured-page-to-per-bubble fallback may make a second request
with the same selected model, but it never changes models.

## Settings

The AI settings section links to an API profile manager. Users can:

- add, edit, and delete parent API profiles
- save multiple child model names under each profile
- choose one child model
- mark one parent profile active
- test the selected profile and child model

OCR and vision do not expose separate model selectors.

## Backup and migration

Settings backup version 6 includes all profile metadata, API keys, and active
profile ID. Version 5 and older backups restore their legacy AI fields and then
migrate into one profile. Restoring profiles replaces profiles with matching
IDs and writes their keys to Keychain.

## Verification

Tests cover normalization, legacy migration, active selection, one-model request
resolution, backup round-trip, and deletion fallback. Final verification uses
Xcode 27 Beta tests plus build/install/launch on the 郑云凯 device.
