/* The first-visit tour is deliberately independent from the app's data layer.
 * It only displays existing features; the app owns account persistence and
 * decides when to offer browser notifications after this tour closes. */
(function () {
    'use strict';

    const steps = [
        {
            label: 'Знакомство',
            title: 'Капани — свой уголок в интернете.',
            description: 'Это место для жителей Капаней. Здесь общаются, узнают новости, заказывают услуги, зарабатывают внутренние рубли и участвуют в жизни посёлка. Покажу самое главное.',
            visual: `<div class="kp-tour-logo">К<span>.</span></div><div class="kp-tour-art-title">Всё своё. Всё рядом.</div><div class="kp-tour-art-tags"><span>Люди</span><span>Новости</span><span>Дела</span></div>`
        },
        {
            label: 'Общение',
            title: 'Начни с людей.',
            description: 'В «Чатах» есть общий разговор всего посёлка и личные сообщения. В «Новостях» — объявления и события. А в «Профиле» можно рассказать о себе и что-нибудь опубликовать.',
            visual: `<div class="kp-tour-art-label">Чаты Капаней</div><div class="kp-tour-message"><span class="kp-tour-avatar">К</span><span>Кто сегодня на связи?</span></div><div class="kp-tour-message is-own"><span>Я тут, привет!</span></div><div class="kp-tour-news-strip"><span class="kp-tour-news-dot"></span>Новости и события посёлка</div>`
        },
        {
            label: 'Покупки и деньги',
            title: 'Местная экономика тоже здесь.',
            description: 'В «Банке» лежат внутренние рубли Капаней: можно переводить их другим жителям и откладывать на накопительный счёт. В «Маркете» — объявления, а в «Бизнесах» — местные товары и услуги.',
            visual: `<div class="kp-tour-wallet"><span>Банк Капани</span><strong>0 ₽</strong><small>Твой виртуальный баланс</small></div><div class="kp-tour-art-grid"><span>К-маркет</span><span>Бизнесы</span></div>`
        },
        {
            label: 'Услуги и работа',
            title: 'Дел хватает и вне чатов.',
            description: 'Нужно доехать — открывай «Такси». Что-то привезти — «Доставку». Подработка ищется в «Работе» и «Заданиях». А если захочется своего дела, загляни в «Бизнесы» и «Здания».',
            visual: `<div class="kp-tour-art-label">Сервисы посёлка</div><div class="kp-tour-service-grid"><span><b>01</b>Такси</span><span><b>02</b>Доставка</span><span><b>03</b>Работа</span><span><b>04</b>Задания</span></div>`
        },
        {
            label: 'Готово',
            title: 'Теперь можно осмотреться самому.',
            description: 'На главной найдёшь больницу, обучение и КВЭ, мероприятия и другие разделы. В мэрии решают вопросы посёлка, а рабочие панели открываются после назначения на должность. Потеряешься — жми «Главная».',
            visual: `<div class="kp-tour-art-label">Куда дальше?</div><div class="kp-tour-last"><div class="kp-tour-last-primary">Главная<span>Все сервисы под рукой</span></div><div>Чаты <span>Общайся</span></div><div>Профиль <span>Твоя страница</span></div></div>`
        }
    ];

    window.kapaniOnboardingStart = function ({ onDone } = {}) {
        if (document.getElementById('kpFirstVisitTour')) return false;

        let stepIndex = 0;
        let changing = false;
        let finishing = false;
        const previousFocus = document.activeElement;
        const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ||
            document.documentElement.classList.contains('v8-reduce-motion');
        const animationTime = reducedMotion ? 0 : 175;
        const root = document.createElement('div');
        root.id = 'kpFirstVisitTour';
        root.className = 'kp-tour-overlay';
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        root.setAttribute('aria-labelledby', 'kpTourTitle');
        root.innerHTML = `
          <div class="kp-tour-panel">
            <div class="kp-tour-top"><span class="kp-tour-brand">Капани <span class="kp-tour-brand-dot"></span> первое знакомство</span><button class="kp-tour-skip" type="button">Пропустить</button></div>
            <div class="kp-tour-stage" id="kpTourStage">
              <div class="kp-tour-art" id="kpTourArt" aria-hidden="true"></div>
              <div class="kp-tour-copy"><div class="kp-tour-label" id="kpTourLabel"></div><h2 id="kpTourTitle"></h2><p id="kpTourDescription"></p></div>
            </div>
            <div class="kp-tour-bottom">
              <div class="kp-tour-progress" aria-label="Ход знакомства"><span id="kpTourCount"></span><div class="kp-tour-track"><span id="kpTourFill"></span></div></div>
              <div class="kp-tour-controls"><button type="button" class="kp-tour-back">Назад</button><button type="button" class="kp-tour-next">Дальше <span aria-hidden="true">→</span></button></div>
            </div>
          </div>`;

        const stage = root.querySelector('#kpTourStage');
        const back = root.querySelector('.kp-tour-back');
        const next = root.querySelector('.kp-tour-next');
        const skip = root.querySelector('.kp-tour-skip');

        function render() {
            const step = steps[stepIndex];
            root.querySelector('#kpTourLabel').textContent = step.label;
            root.querySelector('#kpTourTitle').textContent = step.title;
            root.querySelector('#kpTourDescription').textContent = step.description;
            root.querySelector('#kpTourArt').innerHTML = step.visual;
            root.querySelector('#kpTourCount').textContent = `${String(stepIndex + 1).padStart(2, '0')} / ${String(steps.length).padStart(2, '0')}`;
            root.querySelector('#kpTourFill').style.width = `${(stepIndex + 1) / steps.length * 100}%`;
            back.hidden = stepIndex === 0;
            next.textContent = stepIndex === steps.length - 1 ? 'Открыть Капани' : 'Дальше →';
            next.setAttribute('aria-label', stepIndex === steps.length - 1 ? 'Завершить знакомство и открыть Капани' : 'Следующий экран');
        }

        function move(direction) {
            if (finishing || changing) return;
            const target = stepIndex + direction;
            if (target < 0) return;
            if (target >= steps.length) { finish(); return; }
            changing = true;
            stage.classList.add('kp-tour-stage-out');
            window.setTimeout(() => {
                stepIndex = target;
                render();
                stage.classList.remove('kp-tour-stage-out');
                stage.classList.add('kp-tour-stage-in');
                window.setTimeout(() => {
                    stage.classList.remove('kp-tour-stage-in');
                    changing = false;
                }, animationTime);
            }, animationTime);
        }

        function finish() {
            if (finishing) return;
            finishing = true;
            root.classList.add('kp-tour-closing');
            window.setTimeout(() => {
                root.remove();
                document.body.classList.remove('kp-tour-open');
                document.removeEventListener('keydown', onKeydown, true);
                try { previousFocus?.focus?.({ preventScroll: true }); } catch (_) {}
                try { onDone?.(); } catch (error) { console.error('[Kapani onboarding] completion:', error); }
            }, reducedMotion ? 0 : 240);
        }

        function onKeydown(event) {
            if (event.key === 'Escape') { event.preventDefault(); finish(); return; }
            if (event.key === 'ArrowRight') { event.preventDefault(); move(1); return; }
            if (event.key === 'ArrowLeft') { event.preventDefault(); move(-1); return; }
            if (event.key !== 'Tab') return;
            const available = [...root.querySelectorAll('button:not([hidden]):not([disabled])')];
            if (!available.length) return;
            const first = available[0], last = available[available.length - 1];
            if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
            else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
        }

        skip.addEventListener('click', finish);
        back.addEventListener('click', () => move(-1));
        next.addEventListener('click', () => move(1));
        render();
        document.body.appendChild(root);
        document.body.classList.add('kp-tour-open');
        document.addEventListener('keydown', onKeydown, true);
        next.focus({ preventScroll: true });
        return true;
    };
})();
