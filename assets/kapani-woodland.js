/* Presentation bindings for the existing app and its renderers. */
(() => {
  'use strict';

  const byId = id => document.getElementById(id);
  const app = byId('mainApp');
  const profile = byId('profile');
  const notifications = byId('woodNotificationsOpen');
  const activityHeading = profile.querySelector('.wood-activity-heading');

  function activity(open, focus = false) {
    profile.classList.toggle('wood-activity', open);
    activityHeading.hidden = !open;
    notifications.setAttribute('aria-pressed', String(open));
    if (focus) {
      window.scrollTo(0, 0);
      (open ? activityHeading : profile.querySelector('.wood-profile-heading')).querySelector('h1').focus({preventScroll: true});
    }
  }

  function openActivity() {
    window.navTo('profile');
    activity(true, true);
  }

  byId('woodActivityOpen').addEventListener('click', openActivity);
  notifications.addEventListener('click', openActivity);
  byId('woodActivityBack').addEventListener('click', () => activity(false, true));
  document.querySelector('#gHeader .h-left').addEventListener('click', () => activity(false));
  byId('bn7').addEventListener('click', () => activity(false));
  profile.querySelector('.wood-profile-heading h1').tabIndex = -1;
  activity(false);
  new MutationObserver(() => {
    if (!profile.classList.contains('active') && profile.classList.contains('wood-activity')) activity(false);
  }).observe(profile, {attributes: true, attributeFilter: ['class']});

  // Only list sections with an existing public entry point, or a visible role-gated button.
  const sections = [
    ['Главная', 'home'], ['Чаты и сообщения', 'messages'], ['К-маркет', 'market', 'маркетплейс'],
    ['Задания', 'tasks'], ['Банк', 'bank', 'деньги переводы баланс'], ['Новости', 'news'],
    ['Профиль', 'profile'], ['Уведомления и активность', openActivity, 'push оповещения лента'],
    ['Такси', 'taxi'], ['Заказать доставку', 'deliveryOrderPage', 'корзина доставка'],
    ['Подписка', 'subscription', 'плюс plus ultra prime'],
    ['Бизнесы', 'businesses'], ['Аренда зданий', 'rentBuildings'], ['Работа', 'jobs'],
    ['Мероприятия', 'events'], ['Рейтинг', 'ratings'], ['Больница', 'hospital'],
    ['Казино', 'casino'], ['К-образование', 'kEducation'],
    ['Экзамен КВЭ', 'kveExam', '', 'bn11'], ['Уборщик', 'janitorPage', '', 'bn8'],
    ['Мэрия', 'adminPage', '', 'mayorHeaderBtn'], ['О Капанях', () => window.openInfoModal()],
    ['KapaniGPT', () => document.querySelector('.header-links button[onclick*="kapanigpt"]').click()],
    ['Фильмы KapaniPride', () => document.querySelector('.header-links button[onclick*="kapanipride"]').click()]
  ];
  const dialog = byId('woodSearch');
  const searchButton = byId('woodSearchOpen');
  const searchInput = byId('woodSearchInput');
  const results = byId('woodSearchResults');

  function findSections() {
    const tokens = searchInput.value.trim().toLocaleLowerCase('ru-RU').split(/\s+/).filter(Boolean);
    const buttons = sections.filter(([title, , keywords = '', gate]) => {
      if (gate && byId(gate)?.style.display === 'none') return false;
      const description = (title + ' ' + keywords).toLocaleLowerCase('ru-RU');
      return tokens.every(token => description.includes(token));
    }).map(([title, target]) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'btn btn-ghost';
      button.textContent = title;
      button.addEventListener('click', () => {
        dialog.close();
        if (typeof target === 'function') target();
        else {
          activity(false);
          window.navTo(target);
        }
      });
      return button;
    });
    if (buttons.length) results.replaceChildren(...buttons);
    else {
      const empty = document.createElement('p');
      empty.textContent = 'Разделы не найдены.';
      results.replaceChildren(empty);
    }
  }

  function openSearch() {
    if (dialog.open || !searchButton.getClientRects().length) return;
    searchInput.value = '';
    findSections();
    searchButton.focus({preventScroll: true});
    dialog.showModal();
    searchInput.focus();
  }

  searchButton.addEventListener('click', openSearch);
  searchInput.addEventListener('input', findSections);
  searchInput.addEventListener('keydown', event => {
    if (event.key === 'Enter') results.querySelector('button')?.click();
    if (event.key === 'ArrowDown' && results.firstElementChild?.matches('button')) {
      event.preventDefault();
      results.firstElementChild.focus();
    }
  });
  dialog.addEventListener('click', event => {
    if (event.target === dialog) {
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
    }
  });
  document.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && searchButton.getClientRects().length) {
      event.preventDefault();
      openSearch();
    }
  });

  function mirror(source, destination, suffix = '') {
    const element = byId(source);
    const target = byId(destination);
    const refresh = () => { target.textContent = element.textContent.trim() + suffix; };
    new MutationObserver(refresh).observe(element, {childList: true, characterData: true, subtree: true});
    refresh();
  }
  mirror('hBal', 'v8BankBalance', ' ₽');
  mirror('savingsBalanceDisplay', 'woodSavingsBalance');
  mirror('savingsRateDisplay', 'woodSavingsRate');

  const dayFormat = new Intl.DateTimeFormat('ru-RU', {weekday:'short'});
  const moneyFormat = new Intl.NumberFormat('ru-RU', {maximumFractionDigits:2});
  window.kapaniPaintBankWeek = transactions => {
    const host = byId('woodBankWeek');
    if (!transactions) {
      host.textContent = 'Не удалось загрузить операции за неделю.';
      return;
    }
    const today = new Date();
    const days = Array.from({length: 7}, (_, index) => {
      const date = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 6 + index);
      return {date, key: date.toDateString(), in: 0, out: 0};
    });
    const grouped = new Map(days.map(day => [day.key, day]));
    for (const transaction of transactions) {
      const date = transaction.ts ? new Date(transaction.ts) : new Date(NaN);
      const day = grouped.get(date.toDateString());
      const amount = Number(transaction.amt);
      if (day && (transaction.type === 'in' || transaction.type === 'out') && Number.isFinite(amount)) {
        day[transaction.type] += Math.abs(amount);
      }
    }
    const format = value => moneyFormat.format(value) + ' ₽';
    const legend = document.createElement('div');
    legend.className = 'wood-week-legend';
    const chart = document.createElement('div');
    chart.className = 'wood-week-chart';
    chart.setAttribute('role', 'list');
    chart.setAttribute('aria-label', 'Суммы по дням за последние семь дней');
    const peak = Math.max(1, ...days.flatMap(day => [day.in, day.out]));
    for (const [direction, label] of [['in','Доходы'], ['out','Расходы']]) {
      const text = document.createElement('span');
      text.className = 'wood-' + direction;
      text.textContent = label + ' ' + format(days.reduce((sum, day) => sum + day[direction], 0));
      legend.append(text);
    }
    for (const day of days) {
      const column = document.createElement('div');
      column.className = 'wood-chart-day';
      column.setAttribute('role', 'listitem');
      const label = document.createElement('span');
      label.textContent = dayFormat.format(day.date);
      const summary = day.date.toLocaleDateString('ru-RU') + '. Доходы ' + format(day.in) + '. Расходы ' + format(day.out);
      label.setAttribute('aria-label', summary);
      column.title = summary;
      const bars = document.createElement('div');
      bars.className = 'wood-chart-bars';
      bars.setAttribute('aria-hidden', 'true');
      for (const direction of ['in', 'out']) {
        const bar = document.createElement('span');
        bar.className = 'wood-' + direction;
        bar.style.height = (day[direction] / peak * 100) + '%';
        bars.append(bar);
      }
      column.append(bars, label);
      chart.append(column);
    }
    host.replaceChildren(legend, chart);
  };

  function setStep(list, position) {
    Array.from(list.children).forEach((step, index) => {
      if (index === position) step.setAttribute('aria-current', 'step');
      else step.removeAttribute('aria-current');
    });
  }

  const taxiFrom = byId('tFrom');
  const taxiTo = byId('tTo');
  const taxiSteps = byId('woodTaxiSteps');
  const taxiSubmit = byId('btnCallTaxi');

  function refreshTaxi() {
    const from = taxiFrom.value.trim();
    const to = taxiTo.value.trim();
    byId('woodTaxiFrom').textContent = from || 'Выберите точку посадки';
    byId('woodTaxiTo').textContent = to || 'Выберите пункт назначения';
    setStep(taxiSteps, !taxiSubmit.disabled ? 2 : from ? 1 : 0);
  }
  // App-owned map/geocoder updates emit this event after changing the input values.
  byId('taxiForm').addEventListener('input', refreshTaxi);
  new MutationObserver(refreshTaxi).observe(taxiSubmit, {attributes: true, attributeFilter: ['disabled']});
  refreshTaxi();

  const source = byId('deliveryOrderSource');
  const sourceButtons = Array.from(app.querySelectorAll('[data-wood-source]'));
  const deliverySteps = byId('woodDeliverySteps');
  function refreshDelivery() {
    sourceButtons.forEach(button => {
      button.setAttribute('aria-pressed', String(button.dataset.woodSource === source.value));
    });
    const business = source.value === 'business';
    const selected = business ? byId('deliveryOrderBiz').value : byId('deliveryOrderMarketItem').value;
    const hasProducts = business ? Boolean(byId('deliverySelectionSummary').querySelector('strong')) : Boolean(selected);
    setStep(deliverySteps, hasProducts ? 2 : selected || !business ? 1 : 0);
  }
  sourceButtons.forEach(button => {
    button.addEventListener('click', () => {
      if (source.value === button.dataset.woodSource) return;
      source.value = button.dataset.woodSource;
      source.dispatchEvent(new Event('change', {bubbles: true}));
    });
  });
  source.addEventListener('change', refreshDelivery);
  byId('deliveryOrderPage').addEventListener('change', refreshDelivery);
  new MutationObserver(refreshDelivery).observe(byId('deliverySelectionSummary'), {childList: true, subtree: true, attributes: true, attributeFilter: ['style']});
  new MutationObserver(refreshDelivery).observe(byId('deliverySourceHint'), {childList: true, attributes: true, attributeFilter: ['style']});
  source.hidden = true;
  sourceButtons[0].parentElement.hidden = false;
  refreshDelivery();
})();
