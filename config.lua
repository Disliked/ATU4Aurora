local config = {
    provider = "xboxunity",
    download_root = "Hdd1:\\Aurora\\AutoTU\\Downloads\\",
    output_root = "Hdd1:\\Content\\0000000000000000\\",
    content_root = "Hdd1:\\Content\\0000000000000000\\",
    cache_root = "Hdd1:\\Cache\\",
    log_path = "Hdd1:\\Aurora\\AutoTU\\autotu.log",
    state_path = "Hdd1:\\Aurora\\AutoTU\\state.json",
    dry_run = true,
    max_retries = 3,
    retry_delay_ms = 2000,
    target_path_mode = "configurable",
    target_subpath_template = "{title_id}\\000B0000\\",
    overwrite_existing = false,
    mock_match_all_titles = true,
    xboxunity_api_key = "",
    xboxunity_username = "",
    -- USER ACTION: Leave credentials blank for public TU lookup/download, or fill them if you want to keep account details nearby for future extensions.
    -- ASSUMPTION: the live public TitleUpdateInfo.php and TitleUpdate.php flow does not require these legacy template values.
    xboxunity_lookup_url_template = "",
    xboxunity_download_url_template = ""
}

return config
