import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "AnkiFlashcards.koplugin"


def read(name: str) -> str:
    return (PLUGIN / name).read_text(encoding="utf-8")


def test_ai_provider_settings_expose_provider_model_fields():
    settings = read("settings_viewer.lua")

    for key in [
        "model",
        "image_model",
        "gemini_text_model",
        "gemini_image_model",
        "openai_model",
        "openai_image_model",
        "openrouter_model",
        "openrouter_image_model",
    ]:
        assert re.search(rf'key\s*=\s*"{key}"', settings)

    assert "Text model" in settings
    assert "Image model" in settings


def test_image_generators_use_configurable_model_names():
    image_generator = read("image_generator.lua")

    assert 'config.image_model or "qwen-image-plus"' in image_generator
    assert 'config.gemini_image_model or "gemini-2.5-flash-image"' in image_generator
    assert 'config.openai_image_model or "gpt-image-1"' in image_generator
    assert 'config.openrouter_image_model or "google/gemini-3.1-flash-image-preview"' in image_generator


def test_configuration_sample_documents_model_keys():
    sample = read("configuration.lua.sample")

    for key in [
        "model",
        "image_model",
        "gemini_text_model",
        "gemini_image_model",
        "openai_model",
        "openai_image_model",
        "openrouter_model",
        "openrouter_image_model",
    ]:
        assert key in sample


def test_legacy_anki_model_does_not_override_text_model():
    settings = read("settings_viewer.lua")
    main = read("main.lua")

    assert "cfg.anki_model = saved.model" in settings
    assert 'cfg.model = base_config and base_config.model or "qwen-plus"' in settings
    assert 'key ~= "model" or (saved_anki[key] ~= "Vocabulary"' in main
