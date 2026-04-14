package de.sharedinbox.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.SyncSettings
import de.sharedinbox.core.repository.SyncSettingsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class SyncSettingsViewModel(
    private val repo: SyncSettingsRepository,
) : ViewModel() {
    private val _settings = MutableStateFlow(SyncSettings())
    val settings: StateFlow<SyncSettings> = _settings.asStateFlow()

    init {
        viewModelScope.launch {
            _settings.value = repo.get()
        }
    }

    fun save(settings: SyncSettings) {
        _settings.value = settings
        viewModelScope.launch { repo.save(settings) }
    }
}
