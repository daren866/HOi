/*
 * Copyright (c) 2024-2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "adapter/ios/entrance/picker/picker_haptic_factory.h"
#include "adapter/ios/entrance/picker/picker_haptic_impl.h"

namespace OHOS::Ace::NG {
std::shared_ptr<IPickerAudioHaptic> PickerAudioHapticFactory::instance_ { nullptr };
std::mutex PickerAudioHapticFactory::mutex_;

std::shared_ptr<IPickerAudioHaptic> PickerAudioHapticFactory::GetInstance(
    const std::string& uri, const std::string& effectId)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (instance_ == nullptr) {
        instance_ = std::make_shared<PickerAudioHapticImpl>(uri, effectId);
    }
    return instance_;
}
} // namespace OHOS::Ace::NG
