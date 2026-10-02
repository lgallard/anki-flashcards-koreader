from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "AnkiFlashcards.koplugin"


def read(name: str) -> str:
    return (PLUGIN / name).read_text(encoding="utf-8")


def test_text_only_setting_is_discoverable_and_persisted_when_false():
    settings = read("settings_viewer.lua")
    main = read("main.lua")
    manager = read("card_manager.lua")
    sample = read("configuration.lua.sample")

    assert 'cfg.images_enabled = not images_enabled' in settings
    assert '_("Images: OFF (text-only)")' in settings
    assert '"images_enabled",' in main
    assert 'saved_anki[key] ~= nil' in main
    assert '"images_enabled",' in manager
    assert 'new_cfg[key] ~= nil' in manager
    assert "images_enabled = true" in sample


def test_text_only_omits_image_prompt_and_ankivocab_image_request():
    generator = read("card_generator.lua")

    assert "TEXT_ONLY_PROMPT_TEMPLATE" in generator
    assert "TEXT_ONLY_REGEN_PROMPT" in generator
    assert "config.images_enabled == false" in generator
    assert 'and config.image_provider == "ankivocab"' in generator
    assert "if include_image then" in generator
    assert "card.image_prompt = data.image_prompt or \"\"" in generator
    assert "card._image_url = data.image_url" in generator


def test_text_only_blocks_all_image_generation_entry_points():
    image_generator = read("image_generator.lua")
    main = read("main.lua")
    manager = read("card_manager.lua")
    inbox = read("highlight_inbox.lua")

    assert "function ImageGenerator.images_enabled(config)" in image_generator
    assert "if not ImageGenerator.images_enabled(config) then return end" in image_generator
    assert "if not ImageGenerator.images_enabled(img_cfg) then return false end" in main
    assert "ImageGenerator.images_enabled(CONFIGURATION) and function()" in main
    assert "ImageGenerator.images_enabled(base_config) and function()" in manager
    assert "and ImageGenerator.images_enabled(img_cfg)" in manager
    assert "card.image_prompt and ImageGenerator.images_enabled(config)" in inbox
