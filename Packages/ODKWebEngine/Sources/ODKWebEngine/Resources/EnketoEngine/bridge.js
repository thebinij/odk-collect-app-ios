// Bridges the bundled Enketo engine (enketo-transformer + enketo-core) to the Swift
// host. The engine's own rendered HTML is never shown to the user — it exists purely
// as a headless XForm "logic engine" (XPath relevant/calculate/constraint evaluation
// and instance-XML serialization). All question content and structure is read via
// `getQuestions()`, and all edits go through `setValue()`, so a fully native SwiftUI
// one-question-at-a-time UI can drive the exact same model enketo-core validates and
// finally submits.
// This engine is never shown to the user (see the module doc below), so any browser
// dialog enketo-core triggers internally (e.g. repeat removal's confirm prompt) must
// resolve on its own rather than wait for a tap that can never come — the native UI is
// what actually asks the user to confirm, before it ever calls into the bridge.
window.confirm = function () {
    return true;
};
window.alert = function () {};
window.prompt = function () {
    return null;
};

// Same reasoning, for a subtler case: this document is never shown, but a
// `<input type="date">`/`type="time"` element that actually receives *focus*
// makes iOS present its native date/time picker as a full-screen system
// overlay — completely independent of this WKWebView's own 0×0/opacity:0
// styling, since that overlay isn't part of the WebView's own view hierarchy
// at all. Unlike the keyboard, it doesn't auto-dismiss, so it sits on screen
// until manually closed — and worse, the calendar it shows is always the
// system's own (Gregorian/English), giving no way to make it honor a
// `bikram-sambat` appearance. enketo-core's own date/time widget code can call
// `.focus()` on its underlying native input as part of syncing a
// programmatically-set value (exactly what `setValue()` below does on every
// edit) — since nothing in this document should ever actually receive focus,
// neutralize it globally, the same way confirm/alert/prompt are neutralized.
HTMLElement.prototype.focus = function () {};

window.ODKBridge = (function () {
    let form = null;

    function notify(type, payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.odk) {
            window.webkit.messageHandlers.odk.postMessage(Object.assign({ type: type }, payload || {}));
        }
    }

    async function loadForm(xformXML, instanceXML) {
        try {
            const result = await window.EnketoTransform({ xform: xformXML, markdown: true });
            document.getElementById('form-container').innerHTML = result.form;
            const formEl = document.querySelector('#form-container form.or');
            if (!formEl) {
                throw new Error('The transformed form is missing its expected root element.');
            }
            const data = { modelStr: result.model };
            if (instanceXML) {
                data.instanceStr = instanceXML;
            }
            form = new window.EnketoCoreBundle.Form(formEl, data, {});
            const loadErrors = form.init() || [];
            notify('formReady', { loadErrors: loadErrors });
        } catch (error) {
            notify('formError', { message: (error && error.message) || String(error) });
        }
    }

    function submit() {
        if (!form) {
            notify('submitError', { message: 'The form has not finished loading yet.' });
            return;
        }
        form.validate()
            .then(function (valid) {
                if (!valid) {
                    notify('validationFailed', {});
                    return;
                }
                notify('submissionReady', { xml: form.getDataStr() });
            })
            .catch(function (error) {
                notify('submitError', { message: (error && error.message) || String(error) });
            });
    }

    // Saves whatever has been filled in so far, valid or not — no validation, just a
    // checkpoint the user can resume later.
    function save() {
        if (!form) {
            notify('saveError', { message: 'The form has not finished loading yet.' });
            return;
        }
        try {
            notify('draftReady', { xml: form.getDataStr() });
        } catch (error) {
            notify('saveError', { message: (error && error.message) || String(error) });
        }
    }

    // MARK: - Headless model access (native one-question-at-a-time UI)

    function escapeAttrValue(value) {
        return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    }

    // `data-contains-ref-target="<ref>"` is NOT a reliable "find the question
    // wrapper for this ref" marker — enketo-core also stamps it onto a select's
    // hidden itemset TEMPLATE `<label>` (the node it clones real options from),
    // which sits *inside* the real `.question` wrapper but contains none of its
    // content (no `.question-label`, no `.or-hint`). Matching on it directly used
    // to resolve to that empty template for any select backed by an itemset —
    // reporting a blank label/hint even though the question itself was otherwise
    // fine. Instead, find the real control(s) by name and ask enketo-core's own
    // `getWrapNode` (`control.closest('.question, .calculation, ...')`) for their
    // true wrapper — the same resolution enketo-core uses internally for
    // validity/CSS state, so it can't disagree with how the engine itself treats
    // the question.
    function controlsForRef(ref) {
        const all = document.querySelectorAll(
            '[data-name="' + escapeAttrValue(ref) + '"], [name="' + escapeAttrValue(ref) + '"]'
        );
        return Array.prototype.filter.call(all, function (el) {
            return !el.closest('.itemset-template');
        });
    }

    function findWrapper(ref, index) {
        if (!form) return null;
        const wrappers = [];
        controlsForRef(ref).forEach(function (control) {
            const wrapper = form.input.getWrapNode(control);
            if (wrapper && wrappers.indexOf(wrapper) === -1) {
                wrappers.push(wrapper);
            }
        });
        return wrappers[index || 0] || null;
    }

    function findControl(ref, index) {
        const wrapper = findWrapper(ref, index);
        return wrapper ? wrapper.querySelector('[data-ref]') : null;
    }

    function nearestRepeat(wrapperEl) {
        const section = wrapperEl.closest('.or-repeat');
        if (!section) {
            return { repeatRef: null, repeatIndex: null, repeatCount: null };
        }
        const repeatRef = section.getAttribute('name');
        const siblings = Array.prototype.slice.call(
            document.querySelectorAll('.or-repeat[name="' + escapeAttrValue(repeatRef) + '"]')
        );
        return {
            repeatRef: repeatRef,
            repeatIndex: siblings.indexOf(section),
            repeatCount: siblings.length
        };
    }

    // Enketo renders select options in several structurally different ways
    // depending on appearance AND host platform, and `questionOptions` has to
    // handle all of them:
    //
    //  - static items (default): ONE shared `.option-wrapper` div, directly
    //    containing all the `<label>` option rows.
    //  - dynamic itemset (e.g. a cascading country → city dropdown — a very common
    //    ODK pattern): `data-contains-ref-target` sits on the itemset's own
    //    TEMPLATE `<label>`, which is a CHILD of `.option-wrapper` — an ancestor,
    //    not a descendant — alongside the real cloned option rows as its siblings.
    //  - `appearance="minimal"` on a *touch* device (this app, always): a plain
    //    native `<select multiple?><option>` — no `.option-wrapper` at all.
    //    enketo-core picks this over the desktop bootstrap-select dropdown widget
    //    specifically because it's the better choice on touch/mobile, so this is
    //    the path real usage always takes, not a fallback.
    //  - `appearance="autocomplete"`: no `.option-wrapper`/radio/checkbox at all —
    //    options live in a `<datalist>` instead.
    function questionOptions(wrapperEl) {
        const datalist = wrapperEl.querySelector('datalist');
        if (datalist) {
            return Array.prototype.map
                .call(datalist.querySelectorAll('option'), function (opt) {
                    return { value: opt.getAttribute('data-value') || '', label: opt.value || '' };
                })
                .filter(function (opt) { return opt.value !== ''; });
        }

        const selectEl = wrapperEl.querySelector('select');
        if (selectEl) {
            return Array.prototype.map
                .call(selectEl.querySelectorAll('option'), function (opt) {
                    return { value: opt.value, label: opt.textContent.trim() };
                })
                .filter(function (opt) { return opt.value !== ''; });
        }

        let containers = Array.prototype.slice.call(wrapperEl.querySelectorAll('.option-wrapper'));
        if (containers.length === 0) {
            const ancestor = wrapperEl.closest('.option-wrapper');
            containers = ancestor ? [ancestor] : [wrapperEl];
        }

        const labels = [];
        containers.forEach(function (container) {
            Array.prototype.forEach.call(container.querySelectorAll(':scope > label'), function (labelEl) {
                // Exclude the itemset's own template row — it's a placeholder
                // (empty value), not a real answerable option; enketo-core clones
                // it into real sibling rows (one per matching instance item) once
                // the itemset is populated.
                if (!labelEl.classList.contains('itemset-template')) {
                    labels.push(labelEl);
                }
            });
        });

        return labels.map(function (labelEl) {
            const input = labelEl.querySelector('input');
            const labelSpan = labelEl.querySelector('.option-label');
            return {
                value: input ? input.value : '',
                label: labelSpan ? labelSpan.textContent.trim() : ''
            };
        });
    }

    function questionKind(wrapperEl, control) {
        const typeXml = control.getAttribute('data-type-xml') || 'string';
        if (wrapperEl.classList.contains('readonly')) {
            return 'note';
        }
        if (wrapperEl.classList.contains('trigger')) {
            return 'trigger';
        }
        if (wrapperEl.querySelector('.rank-widget')) {
            return 'rank';
        }
        if (wrapperEl.querySelector('.range-widget')) {
            return 'range';
        }
        if (typeXml === 'binary') {
            const isDrawing =
                control.getAttribute('data-drawing') === 'true' ||
                wrapperEl.classList.contains('or-appearance-draw') ||
                wrapperEl.classList.contains('or-appearance-signature') ||
                wrapperEl.classList.contains('or-appearance-annotate');
            if (isDrawing) {
                return 'signature';
            }
            const accept = control.getAttribute('accept') || '';
            if (accept.indexOf('audio') !== -1) return 'binaryAudio';
            if (accept.indexOf('video') !== -1) return 'binaryVideo';
            if (accept.indexOf('image') !== -1) return 'binaryImage';
            return 'binaryFile';
        }
        if (typeXml === 'geopoint' || typeXml === 'geotrace' || typeXml === 'geoshape') {
            return typeXml;
        }
        if (wrapperEl.querySelector('.option-wrapper input[type=checkbox]')) {
            return 'select';
        }
        if (wrapperEl.querySelector('.option-wrapper input[type=radio]')) {
            return 'select1';
        }
        // `appearance="autocomplete"` (type-ahead single-select) has no
        // `.option-wrapper`/radio at all — its options live in a `<datalist>`.
        if (wrapperEl.querySelector('datalist')) {
            return 'select1';
        }
        // `appearance="minimal"` on a touch device (this app, always) renders as a
        // plain native `<select multiple?>` — enketo-core's deliberate, better
        // choice for mobile over the desktop-only bootstrap-select dropdown widget.
        const selectEl = wrapperEl.querySelector('select');
        if (selectEl) {
            return selectEl.multiple ? 'select' : 'select1';
        }
        return typeXml;
    }

    function describeQuestion(wrapperEl) {
        const control = wrapperEl.querySelector('[data-ref]');
        if (!control || !form) return null;

        const path = form.input.getName(control);
        const index = form.input.getIndex(control);
        const kind = questionKind(wrapperEl, control);
        const labelEl = wrapperEl.querySelector('.question-label');
        const hintEl = wrapperEl.querySelector('.or-hint');
        // A question's own wrapper only gets `.disabled` when ITS OWN relevant
        // expression is false — if it sits inside an irrelevant group or repeat
        // instance, only that ANCESTOR gets `.disabled`. Walk up (closest() checks
        // the element itself too) so group-level irrelevance is inherited correctly.
        const relevant = !wrapperEl.closest('.disabled');
        const required =
            control.hasAttribute('data-required') || control.getAttribute('required') !== null;
        const readonly = wrapperEl.classList.contains('readonly');
        // Two independent "never show this" signals, on top of `appearance="hidden"`:
        // (1) any node under a `meta` group (/data/meta/instanceID,
        // .../instanceName, .../audit, .../deprecatedID, ...) is always ODK/Enketo
        // bookkeeping, never a real question, no matter how the form happened to
        // compile it a body binding; (2) `or-appearance-hidden` itself, the
        // XLSForm/ODK convention for a value that must never be shown (e.g. a
        // calculated or externally-set value that still needs a body binding).
        // Distinct from `relevant`, which is dynamic — this is a static, always-skip
        // marker reported so the native UI can filter it out, same as it filters
        // groups.
        const isMetaField = /(^|\/)meta\//.test(path);
        const hidden = wrapperEl.classList.contains('or-appearance-hidden') || isMetaField;
        // `appearance="bikram-sambat"` — the ODK/XLSForm convention for a `date`
        // field that should be filled in using Nepal's Bikram Sambat calendar while
        // still storing a plain Gregorian date. enketo-core has no BS-aware widget of
        // its own (this class is just a marker), so the native picker is entirely our
        // own — see BikramSambatCalendar.swift.
        const bikramSambat = wrapperEl.classList.contains('or-appearance-bikram-sambat');
        const needsOptions = kind === 'select' || kind === 'select1' || kind === 'rank';
        const rangeControl = wrapperEl.querySelector('input[type=number], input[type=range]');
        const { repeatRef, repeatIndex, repeatCount } = nearestRepeat(wrapperEl);
        // `appearance="field-list"` on a plain (non-repeat) group is the ODK/XLSForm
        // convention for "show these questions together as one page" — deliberately
        // scoped to `.or-group` only (not `.or-repeat`, which already gets its own
        // one-instance-at-a-time navigation) so the two behaviors never conflict.
        const fieldListGroupEl = wrapperEl.closest('.or-group.or-appearance-field-list');
        const fieldListGroupRef = fieldListGroupEl ? fieldListGroupEl.getAttribute('name') : null;
        const fieldListGroupLabelEl = fieldListGroupEl
            ? fieldListGroupEl.querySelector(':scope > h4 .question-label')
            : null;
        const fieldListGroupLabel = fieldListGroupLabelEl ? fieldListGroupLabelEl.textContent.trim() : null;

        let value = '';
        try {
            value = form.model.node(path, index).getVal();
        } catch (error) {
            value = '';
        }

        return {
            ref: path,
            index: index,
            uid: path + '[' + index + ']',
            typeXml: control.getAttribute('data-type-xml') || 'string',
            kind: kind,
            label: labelEl ? labelEl.textContent.trim() : '',
            hint: hintEl ? hintEl.textContent.trim() : null,
            required: required,
            relevant: relevant,
            readonly: readonly,
            hidden: hidden,
            bikramSambat: bikramSambat,
            value: value,
            options: needsOptions ? questionOptions(wrapperEl) : [],
            rangeMin: kind === 'range' && rangeControl ? rangeControl.getAttribute('min') : null,
            rangeMax: kind === 'range' && rangeControl ? rangeControl.getAttribute('max') : null,
            rangeStep: kind === 'range' && rangeControl ? rangeControl.getAttribute('step') : null,
            repeatRef: repeatRef,
            repeatIndex: repeatIndex,
            repeatCount: repeatCount,
            fieldListGroupRef: fieldListGroupRef,
            fieldListGroupLabel: fieldListGroupLabel
        };
    }

    function repeatSeries() {
        const infos = document.querySelectorAll('#form-container .or-repeat-info');
        return Array.prototype.map.call(infos, function (infoEl) {
            const ref = infoEl.getAttribute('data-name');
            const labelEl = infoEl.closest('.or-group, .or-group-data')
                ? infoEl.closest('.or-group, .or-group-data').querySelector(':scope > h4 .question-label')
                : null;
            return {
                ref: ref,
                label: labelEl ? labelEl.textContent.trim() : ref,
                count: document.querySelectorAll('.or-repeat[name="' + escapeAttrValue(ref) + '"]').length
            };
        });
    }

    // Reports the full, current question list (labels/hints/options are static;
    // relevant/value reflect the model's current state) plus each repeat series' add
    // button, so the native layer can lay out "one question at a time" navigation —
    // including where to offer "add another" — without ever touching the DOM itself.
    function getQuestions() {
        if (!form) {
            notify('questionsError', { message: 'The form has not finished loading yet.' });
            return;
        }
        // `.question` is enketo-core's own canonical wrapper class (see
        // `form.input.getWrapNode`'s `.closest('.question, ...')`) — unlike
        // `[data-contains-ref-target]`, it's never also stamped on a select's
        // internal itemset template, so every element found here is a real,
        // fully-rendered question with its actual label/hint/options in reach.
        const wrappers = document.querySelectorAll('#form-container .question');
        const questions = Array.prototype.map.call(wrappers, describeQuestion).filter(Boolean);
        notify('questions', { questions: questions, repeats: repeatSeries() });
    }

    // Sets one question's value in the model directly (bypassing any visual widget),
    // which triggers enketo-core's normal relevant/calculate cascade, then reports the
    // refreshed question list.
    function setValue(ref, index, value, typeXml) {
        if (!form) return;
        try {
            form.model.node(ref, index).setVal(value, typeXml || 'string');
        } catch (error) {
            notify('questionsError', { message: (error && error.message) || String(error) });
            return;
        }
        getQuestions();
    }

    // Shared by `validateQuestion` and `validateQuestions` — validates one
    // (ref, index)'s `required`/`constraint` and resolves {ref, index, valid,
    // message}; never rejects (a thrown error becomes an invalid result instead)
    // so `Promise.all` in `validateQuestions` can't short-circuit on one failure.
    function validateOne(ref, index) {
        const control = findControl(ref, index);
        if (!control) {
            return Promise.resolve({ ref: ref, index: index, valid: true, message: null });
        }
        return form
            .validateInput(control)
            .then(function (result) {
                const requiredValid = !result || result.requiredValid !== false;
                const constraintValid = !result || result.constraintValid !== false;
                const wrapper = findWrapper(ref, index);
                const messageEl = wrapper
                    ? wrapper.querySelector('.or-required-msg.active, .or-constraint-msg.active')
                    : null;
                return {
                    ref: ref,
                    index: index,
                    valid: requiredValid && constraintValid,
                    message: !requiredValid || !constraintValid
                        ? (messageEl ? messageEl.textContent.trim() : 'This answer is not valid.')
                        : null
                };
            })
            .catch(function (error) {
                return { ref: ref, index: index, valid: false, message: (error && error.message) || String(error) };
            });
    }

    // Validates one question's `required`/`constraint`, reporting {ref, index, valid,
    // message} via `validationResult`, then refreshes the question list (a constraint
    // can itself depend on — and change the display of — other questions).
    function validateQuestion(ref, index) {
        if (!form) return;
        validateOne(ref, index).then(function (result) {
            notify('validationResult', result);
            getQuestions();
        });
    }

    // Validates several questions at once — a `field-list` group's page, answered
    // together — reporting every {ref, index, valid, message} in one
    // `groupValidationResult` message, then refreshing the question list once.
    function validateQuestions(items) {
        if (!form) return;
        Promise.all(items.map(function (item) { return validateOne(item.ref, item.index); }))
            .then(function (results) {
                notify('groupValidationResult', { results: results });
                getQuestions();
            });
    }

    // Adds a new instance to a repeat series (clicks enketo-core's own "add" control
    // internally so its repeat-cloning logic — including default values — still runs).
    function addRepeatInstance(repeatRef) {
        const button = document.querySelector(
            '.or-repeat-info[data-name="' + escapeAttrValue(repeatRef) + '"] .add-repeat-btn'
        );
        if (button) {
            button.click();
        }
        getQuestions();
    }

    function removeRepeatInstance(repeatRef, index) {
        const sections = document.querySelectorAll(
            '.or-repeat[name="' + escapeAttrValue(repeatRef) + '"]'
        );
        const section = sections[index];
        const button = section ? section.querySelector('.repeat-buttons .remove') : null;
        if (!button) {
            getQuestions();
            return;
        }
        // enketo-core's remove goes through its own confirm() dialog, which we've
        // neutralized above to auto-accept — but that still resolves via a Promise, so
        // the actual removal lands a tick after this click, not synchronously with it.
        button.click();
        setTimeout(getQuestions, 0);
    }

    return {
        loadForm: loadForm,
        submit: submit,
        save: save,
        getQuestions: getQuestions,
        setValue: setValue,
        validateQuestion: validateQuestion,
        validateQuestions: validateQuestions,
        addRepeatInstance: addRepeatInstance,
        removeRepeatInstance: removeRepeatInstance
    };
})();
