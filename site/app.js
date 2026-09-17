const switcher = document.querySelector('[data-studio-switcher]');
if (switcher) {
  const list = switcher.querySelector('.tab-list');
  const tabs = [...list.querySelectorAll('button')];
  const panels = tabs.map(tab => document.getElementById(tab.getAttribute('aria-controls')));
  switcher.classList.add('enhanced');
  list.setAttribute('role', 'tablist');
  tabs.forEach(tab => tab.setAttribute('role', 'tab'));
  panels.forEach(panel => { panel.setAttribute('role', 'tabpanel'); panel.tabIndex = 0; });

  function select(index, focus = false) {
    tabs.forEach((tab, i) => {
      tab.setAttribute('aria-selected', String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
      panels[i].hidden = i !== index;
      panels[i].classList.toggle('panel-reveal', i === index);
    });
    if (focus) tabs[index].focus();
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => select(index));
    tab.addEventListener('keydown', event => {
      const positions = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index - 1 + tabs.length) % tabs.length, Home: 0, End: tabs.length - 1 };
      if (Object.hasOwn(positions, event.key)) { event.preventDefault(); select(positions[event.key], true); }
    });
  });
  select(0);
}
